defmodule MOQX.TransportBench.MoqxListener do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.TransportBench.DatagramPayload

  @default_script "moqx-transport-bench moqx-listener"
  @default_timeout_seconds 30
  @datagram_header_size DatagramPayload.header_size()
  @stream_pressure_workload "stream_pressure"
  @datagram_pressure_workload "datagram_pressure"
  @mixed_moqt_shaped_workload "mixed_moqt_shaped"
  @listener_diagnostics_schema_version "moqx-listener-diagnostics-v1"

  def main(argv, opts \\ []) do
    script = Keyword.get(opts, :script, @default_script)
    transport_backend = Keyword.get(opts, :transport_backend, MOQX.Transport.Quicer)
    halt_on_error? = Keyword.get(opts, :halt_on_error?, true)

    ensure_quicer? =
      Keyword.get(opts, :ensure_quicer?, transport_backend == MOQX.Transport.Quicer)

    case parse(argv, script, transport_backend, ensure_quicer?) do
      {:help, message} ->
        IO.puts(message)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(2)

      {:ok, config} ->
        config
        |> Map.put(:halt_on_error?, halt_on_error?)
        |> run()
        |> handle_run_result(halt_on_error?)
    end
  end

  defp parse(argv, script, transport_backend, ensure_quicer?) do
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
          control_payload_size: :integer,
          control_message_count: :integer,
          control_rate: :integer,
          connection_count: :integer,
          timeout_seconds: :integer,
          accept_timeout_seconds: :integer,
          datagram_idle_timeout_ms: :integer,
          diagnostics_output: :string,
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
        build_config(opts, transport_backend, ensure_quicer?)
    end
  end

  defp build_config(opts, transport_backend, ensure_quicer?) do
    config = %{
      transport_backend: transport_backend,
      ensure_quicer?: ensure_quicer?,
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
      control_payload_size: Keyword.get(opts, :control_payload_size, 64),
      control_message_count: Keyword.get(opts, :control_message_count, 10),
      control_rate: Keyword.get(opts, :control_rate, 10),
      connection_count: Keyword.get(opts, :connection_count, 1),
      timeout_ms: Keyword.get(opts, :timeout_seconds, @default_timeout_seconds) * 1000,
      accept_timeout_ms:
        Keyword.get(
          opts,
          :accept_timeout_seconds,
          Keyword.get(opts, :timeout_seconds, @default_timeout_seconds)
        ) * 1000,
      datagram_idle_timeout_ms: opts[:datagram_idle_timeout_ms],
      diagnostics_output: opts[:diagnostics_output]
    }

    with :ok <- validate_positive(config.port, "--port"),
         :ok <- validate_workload(config.workload),
         :ok <- validate_positive(config.stream_count, "--stream-count"),
         :ok <- validate_positive(config.payload_size, "--payload-size"),
         :ok <- validate_positive(config.payload_count, "--payload-count"),
         :ok <- validate_datagram_size(config),
         :ok <- validate_positive(config.datagram_count, "--datagram-count"),
         :ok <- validate_paced_datagrams(config),
         :ok <- validate_mixed_control(config),
         :ok <- validate_non_negative(config.connection_count, "--connection-count"),
         :ok <- validate_positive(config.accept_timeout_ms, "--accept-timeout-seconds"),
         :ok <-
           validate_optional_positive(
             config.datagram_idle_timeout_ms,
             "--datagram-idle-timeout-ms"
           ),
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
       when workload in [
              @stream_pressure_workload,
              @datagram_pressure_workload,
              @mixed_moqt_shaped_workload
            ],
       do: :ok

  defp validate_workload(_workload),
    do: {:error, "--workload must be stream_pressure, datagram_pressure, or mixed_moqt_shaped."}

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

  defp validate_mixed_control(%{workload: @mixed_moqt_shaped_workload} = config) do
    with :ok <- validate_positive(config.control_payload_size, "--control-payload-size"),
         :ok <- validate_positive(config.control_message_count, "--control-message-count") do
      validate_positive(config.control_rate, "--control-rate")
    end
  end

  defp validate_mixed_control(_config), do: :ok

  defp validate_stream_direction(direction)
       when direction in ["bidirectional", "unidirectional"],
       do: :ok

  defp validate_stream_direction(_direction),
    do: {:error, "--stream-direction must be bidirectional or unidirectional."}

  defp validate_file(path, name) do
    if File.exists?(path), do: :ok, else: {:error, "#{name} does not exist: #{path}"}
  end

  defp run(config) do
    with :ok <- ensure_transport_apps(config),
         {:ok, ctx} <- Transport.new(config.transport_backend),
         {:ok, listener, ctx} <- start_listener(ctx, config),
         {:ok, local_address} <- Transport.local_address(ctx, listener),
         listener_metadata = listener_metadata(config, local_address),
         {_ip, port} = local_address,
         :ok <- print_ready(config, port),
         {:ok, ctx} <- serve_connections(ctx, listener, config, listener_metadata),
         {:ok, _ctx} <- Transport.close_listener(ctx, listener, 0) do
      :ok
    else
      {:error, reason, _ctx} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_run_result(:ok, _halt_on_error?), do: :ok

  defp handle_run_result({:error, message} = error, false) when is_binary(message) do
    IO.puts(:stderr, message)
    error
  end

  defp handle_run_result({:error, reason} = error, false) do
    IO.puts(:stderr, inspect(reason))
    error
  end

  defp handle_run_result({:error, message}, true) when is_binary(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  defp handle_run_result({:error, reason}, true) do
    IO.puts(:stderr, inspect(reason))
    System.halt(1)
  end

  defp ensure_transport_apps(%{ensure_quicer?: false}), do: :ok

  defp ensure_transport_apps(%{ensure_quicer?: true}) do
    case Application.ensure_all_started(:quicer) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, reason}
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

  defp serve_connections(ctx, listener, config, listener_metadata) do
    serve_connections(ctx, listener, config, listener_metadata, 0)
  end

  defp serve_connections(ctx, _listener, %{connection_count: limit}, _listener_metadata, served)
       when limit > 0 and served >= limit,
       do: {:ok, ctx}

  defp serve_connections(ctx, listener, config, listener_metadata, served) do
    case Transport.accept(ctx, listener, [], config.accept_timeout_ms) do
      {:ok, connection, ctx} ->
        handshake_connection(ctx, listener, connection, config, listener_metadata, served)

      {:error, reason, ctx} ->
        write_listener_diagnostics(config, listener_metadata, %{
          phase: "accept",
          served: served,
          stop_reason: "accept_error",
          error_reason: reason_name(reason),
          timeout_ms: config.accept_timeout_ms
        })

        {:error, reason, ctx}
    end
  end

  defp handshake_connection(ctx, listener, connection, config, listener_metadata, served) do
    case Transport.handshake(ctx, connection, config.timeout_ms) do
      {:ok, connection, ctx} ->
        serve_connection(ctx, listener, connection, config, listener_metadata, served)

      {:error, reason, ctx} ->
        write_listener_diagnostics(config, listener_metadata, %{
          phase: "handshake",
          served: served,
          stop_reason: "handshake_error",
          error_reason: reason_name(reason),
          timeout_ms: config.timeout_ms
        })

        {:error, reason, ctx}
    end
  end

  defp serve_connection(ctx, listener, connection, config, listener_metadata, served) do
    with {:ok, ctx} <- serve_connection_workload(ctx, connection, config),
         {:ok, close_mode, ctx} <- wait_for_peer_connection_close(ctx, connection, config),
         {:ok, ctx} <- close_connection_if_needed(ctx, connection, close_mode) do
      serve_connections(ctx, listener, config, listener_metadata, served + 1)
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
    state = initial_datagram_receive_state(config)

    case receive_datagrams(ctx, connection, config, state) do
      {:ok, ctx, state} ->
        write_datagram_diagnostics(config, state)
        {:ok, ctx}

      {:error, reason, ctx, state} ->
        write_datagram_diagnostics(config, state)
        {:error, reason, ctx}
    end
  end

  defp serve_connection_workload(
         ctx,
         connection,
         %{workload: @mixed_moqt_shaped_workload} = config
       ) do
    with {:ok, streams, ctx} <- accept_streams(ctx, connection, config) do
      serve_streams(ctx, streams, config)
    end
  end

  defp accept_streams(ctx, connection, config) do
    Enum.reduce_while(1..expected_stream_count(config), {:ok, [], ctx}, fn _index,
                                                                           {:ok, streams, ctx} ->
      case Transport.accept_stream(ctx, connection, [], config.timeout_ms) do
        {:ok, stream, ctx} ->
          stream_state = %{
            stream: stream,
            received: 0,
            expected_bytes: expected_stream_bytes(stream, config),
            chunk_size: stream_chunk_size(stream, config)
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

  defp expected_stream_count(%{workload: @mixed_moqt_shaped_workload} = config),
    do: config.stream_count + 1

  defp expected_stream_count(config), do: config.stream_count

  defp expected_stream_bytes(
         %{info: %{direction: :bidirectional}},
         %{workload: @mixed_moqt_shaped_workload} = config
       ) do
    config.control_payload_size * config.control_message_count
  end

  defp expected_stream_bytes(_stream, config), do: config.payload_size * config.payload_count

  defp stream_chunk_size(
         %{info: %{direction: :bidirectional}},
         %{workload: @mixed_moqt_shaped_workload} = config
       ) do
    config.control_payload_size
  end

  defp stream_chunk_size(_stream, config), do: config.payload_size

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

  defp recv_stream_chunk(ctx, stream_state, _config) do
    remaining = stream_state.expected_bytes - stream_state.received
    chunk_size = min(stream_state.chunk_size, remaining)

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

  defp initial_datagram_receive_state(config) do
    %{
      expected_datagrams: expected_datagram_count(config),
      received_sequences: MapSet.new(),
      started_at: monotonic_us(),
      stop_reason: nil,
      datagrams_received: 0,
      datagrams_echo_attempted: 0,
      datagrams_echoed: 0,
      datagram_duplicates: 0,
      invalid_datagrams: 0,
      ignored_events: 0,
      unknown_events: 0,
      receive_errors: 0,
      echo_errors: 0,
      echo_error_reason: nil,
      process: %{}
    }
    |> sample_datagram_process()
  end

  defp receive_datagrams(ctx, connection, config, state) do
    state = sample_datagram_process(state)

    cond do
      MapSet.size(state.received_sequences) >= state.expected_datagrams ->
        {:ok, ctx, stop_datagram_receive(state, "expected_datagrams_received")}

      datagram_observation_expired?(config, state) ->
        {:ok, ctx, stop_datagram_receive(state, "datagram_observation_timeout")}

      true ->
        receive_datagram(ctx, connection, config, state)
    end
  end

  defp receive_datagram(ctx, connection, config, state) do
    case Transport.receive_event(ctx, datagram_receive_wait_ms(config, state)) do
      {:ok, {:datagram, ^connection, payload, _metadata}, ctx} ->
        state = record_datagram(state, payload)
        echo_datagram(ctx, connection, config, state, payload)

      {:ok, _event, ctx} ->
        state =
          state
          |> Map.update!(:ignored_events, &(&1 + 1))
          |> sample_datagram_process()

        receive_datagrams(ctx, connection, config, state)

      {:timeout, ctx} ->
        handle_datagram_timeout(ctx, state)

      {:unknown, _message, ctx} ->
        state =
          state
          |> Map.update!(:unknown_events, &(&1 + 1))
          |> sample_datagram_process()

        receive_datagrams(ctx, connection, config, state)

      {:error, reason, ctx} ->
        state =
          state
          |> Map.update!(:receive_errors, &(&1 + 1))
          |> sample_datagram_process()
          |> stop_datagram_receive("receive_error")

        {:error, reason, ctx, state}
    end
  end

  defp echo_datagram(ctx, connection, config, state, payload) do
    state = Map.update!(state, :datagrams_echo_attempted, &(&1 + 1))

    case Transport.send_datagram(ctx, connection, payload) do
      {:ok, ctx} ->
        state =
          state
          |> Map.update!(:datagrams_echoed, &(&1 + 1))
          |> sample_datagram_process()

        receive_datagrams(ctx, connection, config, state)

      {:error, reason, ctx} ->
        state =
          state
          |> Map.update!(:echo_errors, &(&1 + 1))
          |> Map.put(:echo_error_reason, reason_name(reason))
          |> sample_datagram_process()
          |> stop_datagram_receive("echo_error")

        {:error, reason, ctx, state}
    end
  end

  defp handle_datagram_timeout(ctx, %{datagrams_received: 0} = state) do
    state = stop_datagram_receive(state, "first_datagram_timeout")
    {:error, "moqx-listener timed out waiting for reference client datagrams", ctx, state}
  end

  defp handle_datagram_timeout(ctx, state) do
    {:ok, ctx, stop_datagram_receive(state, "datagram_idle_timeout")}
  end

  defp record_datagram(state, payload) do
    state = Map.update!(state, :datagrams_received, &(&1 + 1))

    case DatagramPayload.sequence(payload) do
      {:ok, sequence} ->
        if MapSet.member?(state.received_sequences, sequence) do
          Map.update!(state, :datagram_duplicates, &(&1 + 1))
        else
          update_in(state, [:received_sequences], &MapSet.put(&1, sequence))
        end

      :error ->
        Map.update!(state, :invalid_datagrams, &(&1 + 1))
    end
    |> sample_datagram_process()
  end

  defp stream_id(stream), do: stream.info.stream_id

  defp stop_datagram_receive(state, reason) do
    state
    |> Map.put(:stop_reason, reason)
    |> sample_datagram_process()
  end

  defp datagram_observation_expired?(config, state) do
    elapsed_ms(state.started_at) >= datagram_observation_timeout_ms(config)
  end

  defp datagram_receive_wait_ms(config, state) do
    remaining_ms =
      max(datagram_observation_timeout_ms(config) - trunc(elapsed_ms(state.started_at)), 0)

    cond do
      remaining_ms == 0 ->
        0

      state.datagrams_received == 0 ->
        min(config.timeout_ms, remaining_ms)

      true ->
        min(datagram_idle_timeout_ms(config), remaining_ms)
    end
  end

  defp datagram_observation_timeout_ms(
         %{datagram_rate: rate, duration_seconds: duration} = config
       )
       when is_integer(rate) and is_integer(duration) do
    duration * 1000 + config.timeout_ms
  end

  defp datagram_observation_timeout_ms(config), do: config.timeout_ms

  defp datagram_idle_timeout_ms(%{datagram_idle_timeout_ms: timeout_ms})
       when is_integer(timeout_ms) do
    timeout_ms
  end

  defp datagram_idle_timeout_ms(%{datagram_rate: rate, timeout_ms: timeout_ms})
       when is_integer(rate) and rate > 0 do
    rate_interval_bound_ms = ceil(3000 / rate)
    min(max(rate_interval_bound_ms, 1000), timeout_ms)
  end

  defp datagram_idle_timeout_ms(config), do: min(1000, config.timeout_ms)

  defp write_datagram_diagnostics(%{diagnostics_output: nil}, _state), do: :ok

  defp write_datagram_diagnostics(config, state) do
    path = config.diagnostics_output
    dir = Path.dirname(path)
    if dir != ".", do: File.mkdir_p!(dir)

    File.write!(
      path,
      state
      |> datagram_diagnostics_record(config)
      |> encode_json()
      |> IO.iodata_to_binary()
      |> Kernel.<>("\n"),
      [:append]
    )
  end

  defp datagram_diagnostics_record(state, config) do
    unique = MapSet.size(state.received_sequences)

    %{
      "schema_version" => @listener_diagnostics_schema_version,
      "record_type" => "datagram_listener_run",
      "workload" => @datagram_pressure_workload,
      "alpn" => config.alpn,
      "summary" => %{
        "expected_datagrams" => state.expected_datagrams,
        "datagrams_received" => state.datagrams_received,
        "datagrams_unique" => unique,
        "datagrams_missing" => max(state.expected_datagrams - unique, 0),
        "datagrams_echo_attempted" => state.datagrams_echo_attempted,
        "datagrams_echoed" => state.datagrams_echoed,
        "datagram_duplicates" => state.datagram_duplicates,
        "invalid_datagrams" => state.invalid_datagrams,
        "ignored_events" => state.ignored_events,
        "unknown_events" => state.unknown_events,
        "receive_errors" => state.receive_errors,
        "echo_errors" => state.echo_errors,
        "echo_error_reason" => state.echo_error_reason,
        "stop_reason" => state.stop_reason,
        "duration_ms" => elapsed_ms(state.started_at),
        "datagram_idle_timeout_ms" => datagram_idle_timeout_ms(config),
        "datagram_observation_timeout_ms" => datagram_observation_timeout_ms(config)
      },
      "process" => process_diagnostics(state.process)
    }
  end

  defp write_listener_diagnostics(%{diagnostics_output: nil}, _listener_metadata, _summary),
    do: :ok

  defp write_listener_diagnostics(config, listener_metadata, summary) do
    path = config.diagnostics_output
    dir = Path.dirname(path)
    if dir != ".", do: File.mkdir_p!(dir)

    File.write!(
      path,
      config
      |> listener_diagnostics_record(listener_metadata, summary)
      |> encode_json()
      |> IO.iodata_to_binary()
      |> Kernel.<>("\n"),
      [:append]
    )
  end

  defp listener_diagnostics_record(config, listener_metadata, summary) do
    %{
      "schema_version" => @listener_diagnostics_schema_version,
      "record_type" => "listener_accept_run",
      "workload" => config.workload,
      "alpn" => config.alpn,
      "listener" => listener_metadata,
      "summary" => %{
        "phase" => summary.phase,
        "stop_reason" => summary.stop_reason,
        "error_reason" => summary.error_reason,
        "connections_served" => summary.served,
        "connection_count_limit" => config.connection_count,
        "timeout_ms" => summary.timeout_ms
      },
      "process" => process_diagnostics(%{})
    }
  end

  defp listener_metadata(config, {ip, port}) do
    %{
      "configured_host" => config.host,
      "configured_port" => config.port,
      "bound_ip" => format_ip(ip),
      "bound_port" => port
    }
  end

  defp format_ip(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp process_diagnostics(samples) do
    current = message_queue_len()

    peak =
      [current, Map.get(samples, "message_queue_len_peak")]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    %{
      "message_queue_len" => current,
      "message_queue_len_peak" => peak,
      "message_queue_len_samples" => Map.get(samples, "message_queue_len_samples", 0)
    }
  end

  defp sample_datagram_process(state) do
    message_queue_len = message_queue_len()

    process =
      state.process
      |> Map.put("message_queue_len", message_queue_len)
      |> Map.update("message_queue_len_peak", message_queue_len, fn peak ->
        max(peak, message_queue_len)
      end)
      |> Map.update("message_queue_len_samples", 1, &(&1 + 1))

    %{state | process: process}
  end

  defp message_queue_len do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, value} -> value
      nil -> nil
    end
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
  defp elapsed_ms(started_at), do: (monotonic_us() - started_at) / 1000

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(reason), do: inspect(reason)

  defp encode_json(value), do: value |> json_ready() |> :json.encode()

  defp json_ready(nil), do: :null
  defp json_ready(value) when value in [true, false], do: value

  defp json_ready(value) when is_map(value) do
    Map.new(value, fn {key, map_value} -> {key, json_ready(map_value)} end)
  end

  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value), do: value

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
      --workload VALUE               stream_pressure, datagram_pressure, or mixed_moqt_shaped (default: stream_pressure)
      --stream-direction VALUE       bidirectional or unidirectional (default: bidirectional)
      --stream-count N               streams expected from the reference client (default: 1)
      --payload-size BYTES           bytes per payload write (default: 1200)
      --payload-count N              payload writes per stream (default: 1)
      --datagram-size BYTES          bytes per datagram for datagram_pressure (default: 1200)
      --datagram-count N             datagrams expected for datagram_pressure (default: 1000)
      --datagram-rate N              target datagrams/sec expected for paced datagram_pressure
      --duration-seconds N           paced datagram_pressure duration; expected datagrams = rate * duration
      --control-payload-size BYTES   bytes per control message for mixed_moqt_shaped (default: 64)
      --control-message-count N      control messages for mixed_moqt_shaped (default: 10)
      --control-rate N               target control messages/sec for mixed_moqt_shaped (default: 10)
      --connection-count N           accepted connections before exit; 0 means unlimited (default: 1)
      --timeout-seconds N            read/workload timeout per operation after accept (default: #{@default_timeout_seconds})
      --accept-timeout-seconds N     connection accept timeout; defaults to --timeout-seconds
      --datagram-idle-timeout-ms N   datagram receive idle bound after first datagram
      --diagnostics-output PATH      append listener-side diagnostics JSONL

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
