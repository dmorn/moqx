defmodule MOQX.TransportBench.ReferenceComparison do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.TransportBench.BuildInfo
  alias MOQX.TransportBench.DatagramPayload
  alias MOQX.TransportBench.PathMetadata
  alias MOQX.TransportBench.StreamPressureCollector

  @default_script "moqx-transport-bench reference-comparison"
  @script_version "v1"
  @schema_version "transport-bench-v1"
  @timeout_exit_status 124
  @timeout_stop_condition "reference_comparison_step_timeout"
  @datagram_header_size DatagramPayload.header_size()
  @stream_pressure_workload "stream_pressure"
  @datagram_pressure_workload "datagram_pressure"
  @mixed_moqt_shaped_workload "mixed_moqt_shaped"
  @default_stream_send_window 16
  @default_stream_event_batch_size 1
  @stream_diagnostics_sampling_modes ~w(event final)
  @mixed_completion_drain_limit 1024
  @message_queue_sample_prefix_count 16
  @message_queue_sample_stride 1_024
  @reference_client_topology "reference-client-to-reference-server"
  @reference_client_moqx_listener_topology "reference-client-to-moqx-listener"
  @moqx_client_topology "moqx-client-to-reference-server"
  @supported_topologies [
    @reference_client_topology,
    @reference_client_moqx_listener_topology,
    @moqx_client_topology
  ]

  def main(argv, opts \\ []) do
    script = Keyword.get(opts, :script, @default_script)
    transport_backend = Keyword.get(opts, :transport_backend, MOQX.Transport.Quicer)

    case parse(argv, script, transport_backend) do
      {:help, message} ->
        IO.puts(message)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(2)

      {:ok, config} ->
        run(config)
    end
  end

  defp parse(argv, script, transport_backend) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        strict: [
          topology: :string,
          server: :string,
          port: :integer,
          ca: :string,
          servername: :string,
          alpn: :string,
          workload: :string,
          stream_direction: :string,
          stream_count: :integer,
          stream_send_window: :integer,
          stream_event_batch_size: :integer,
          stream_diagnostics_sampling: :string,
          payload_size: :integer,
          payload_count: :integer,
          datagram_size: :integer,
          datagram_count: :integer,
          datagram_rate: :integer,
          duration_seconds: :integer,
          control_payload_size: :integer,
          control_message_count: :integer,
          control_rate: :integer,
          delivery_threshold: :string,
          offered_rate_tolerance: :string,
          timeout_seconds: :integer,
          timeout_margin_seconds: :integer,
          quicprobe_command: :string,
          path_json: :string,
          evidence_tier: :string,
          path_id: :string,
          client_host_id: :string,
          server_host_id: :string,
          client_provider: :string,
          server_provider: :string,
          client_region: :string,
          server_region: :string,
          client_instance_class: :string,
          server_instance_class: :string,
          client_network_class: :string,
          server_network_class: :string,
          run_id: :string,
          output: :string,
          notes: :string,
          help: :boolean
        ],
        aliases: [
          s: :server,
          p: :port,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        {:help, usage(script)}

      invalid != [] ->
        {:error, "Invalid options: #{inspect(invalid)}\n\n#{usage(script)}"}

      is_nil(opts[:topology]) ->
        {:error, "Missing required --topology VALUE.\n\n#{usage(script)}"}

      opts[:topology] not in @supported_topologies ->
        {:error, "Unsupported --topology #{inspect(opts[:topology])}.\n\n#{usage(script)}"}

      is_nil(opts[:server]) ->
        {:error, "Missing required --server HOST.\n\n#{usage(script)}"}

      is_nil(opts[:ca]) ->
        {:error, "Missing required --ca PATH.\n\n#{usage(script)}"}

      true ->
        build_config(opts, argv, script, transport_backend)
    end
  end

  defp build_config(opts, argv, script, transport_backend) do
    config = %{
      argv: argv,
      script: script,
      transport_backend: transport_backend,
      command: command_string(script, argv),
      topology: opts[:topology],
      server: opts[:server],
      port: Keyword.get(opts, :port, 4433),
      ca: opts[:ca],
      servername: opts[:servername],
      alpn: Keyword.get(opts, :alpn, "moqx-test"),
      workload: Keyword.get(opts, :workload, @stream_pressure_workload),
      stream_direction: Keyword.get(opts, :stream_direction, "bidirectional"),
      stream_count: Keyword.get(opts, :stream_count, 1),
      stream_send_window: Keyword.get(opts, :stream_send_window, @default_stream_send_window),
      stream_event_batch_size:
        Keyword.get(opts, :stream_event_batch_size, @default_stream_event_batch_size),
      stream_diagnostics_sampling: Keyword.get(opts, :stream_diagnostics_sampling, "event"),
      payload_size: Keyword.get(opts, :payload_size, 1200),
      payload_count: Keyword.get(opts, :payload_count, 1),
      datagram_size: Keyword.get(opts, :datagram_size, 1200),
      datagram_count: Keyword.get(opts, :datagram_count, 1000),
      datagram_rate: opts[:datagram_rate],
      duration_seconds: opts[:duration_seconds],
      control_payload_size: Keyword.get(opts, :control_payload_size, 64),
      control_message_count: Keyword.get(opts, :control_message_count, 10),
      control_rate: Keyword.get(opts, :control_rate, 10),
      delivery_threshold: parse_delivery_threshold(Keyword.get(opts, :delivery_threshold, "1.0")),
      offered_rate_tolerance:
        parse_delivery_threshold(Keyword.get(opts, :offered_rate_tolerance, "0.95")),
      timeout_seconds: Keyword.get(opts, :timeout_seconds, 5),
      timeout_margin_seconds: Keyword.get(opts, :timeout_margin_seconds, 2),
      quicprobe_command: Keyword.get(opts, :quicprobe_command, "quicprobe"),
      path_json: opts[:path_json],
      path_overrides: path_overrides(opts),
      run_id: opts[:run_id] || default_run_id(opts[:topology], opts[:server]),
      output: opts[:output],
      notes: opts[:notes]
    }

    with :ok <- validate_positive(config.port, "--port"),
         :ok <- validate_workload(config.workload),
         :ok <- validate_positive(config.stream_count, "--stream-count"),
         :ok <- validate_positive(config.stream_send_window, "--stream-send-window"),
         :ok <- validate_positive(config.stream_event_batch_size, "--stream-event-batch-size"),
         :ok <- validate_stream_diagnostics_sampling(config.stream_diagnostics_sampling),
         :ok <- validate_positive(config.payload_size, "--payload-size"),
         :ok <- validate_positive(config.payload_count, "--payload-count"),
         :ok <- validate_datagram_size(config),
         :ok <- validate_positive(config.datagram_count, "--datagram-count"),
         :ok <- validate_paced_datagrams(config),
         :ok <- validate_mixed_control(config),
         :ok <- validate_ratio(config.delivery_threshold, "--delivery-threshold"),
         :ok <- validate_positive_ratio(config.offered_rate_tolerance, "--offered-rate-tolerance"),
         :ok <- validate_positive(config.timeout_seconds, "--timeout-seconds"),
         :ok <- validate_positive(config.timeout_margin_seconds, "--timeout-margin-seconds"),
         :ok <- validate_stream_direction(config.stream_direction) do
      {:ok, config}
    end
  end

  defp validate_positive(value, _name) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(_value, name), do: {:error, "#{name} must be greater than 0."}

  defp validate_optional_positive(nil, _name), do: :ok
  defp validate_optional_positive(value, name), do: validate_positive(value, name)

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

  defp parse_delivery_threshold(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> :invalid
    end
  end

  defp parse_delivery_threshold(value) when is_integer(value) or is_float(value), do: value
  defp parse_delivery_threshold(_value), do: :invalid

  defp validate_ratio(value, _name) when is_number(value) and value >= 0.0 and value <= 1.0,
    do: :ok

  defp validate_ratio(_value, name),
    do: {:error, "#{name} must be a number from 0.0 to 1.0."}

  defp validate_positive_ratio(value, _name)
       when is_number(value) and value > 0.0 and value <= 1.0,
       do: :ok

  defp validate_positive_ratio(_value, name),
    do: {:error, "#{name} must be a number greater than 0.0 and at most 1.0."}

  defp validate_stream_direction(direction)
       when direction in ["bidirectional", "unidirectional"],
       do: :ok

  defp validate_stream_direction(_direction) do
    {:error, "--stream-direction must be bidirectional or unidirectional."}
  end

  defp validate_stream_diagnostics_sampling(mode)
       when mode in @stream_diagnostics_sampling_modes,
       do: :ok

  defp validate_stream_diagnostics_sampling(_mode) do
    {:error, "--stream-diagnostics-sampling must be event or final."}
  end

  defp path_overrides(opts) do
    %{
      "evidence_tier" => opts[:evidence_tier],
      "path_id" => opts[:path_id],
      "client" => %{
        "host_id" => opts[:client_host_id],
        "provider" => opts[:client_provider],
        "region" => opts[:client_region],
        "instance_class" => opts[:client_instance_class],
        "nic_or_network_class" => opts[:client_network_class]
      },
      "server" => %{
        "host_id" => opts[:server_host_id],
        "provider" => opts[:server_provider],
        "region" => opts[:server_region],
        "instance_class" => opts[:server_instance_class],
        "nic_or_network_class" => opts[:server_network_class]
      }
    }
  end

  defp run(config) do
    run_started_at = timestamp()
    step_started_at = timestamp()
    {measurement, output, exit_status, args, timed_out?, timeout_ms} = run_topology(config)
    step_finished_at = timestamp()

    record =
      build_record(%{
        config: config,
        run_started_at: run_started_at,
        step_started_at: step_started_at,
        step_finished_at: step_finished_at,
        exit_status: exit_status,
        step_args: args,
        step_output: output,
        measurement: measurement,
        timed_out?: timed_out?,
        timeout_ms: timeout_ms
      })

    write_records([record], config.output)
  end

  defp run_topology(%{topology: @reference_client_topology} = config), do: run_quicprobe(config)

  defp run_topology(%{topology: @reference_client_moqx_listener_topology} = config),
    do: run_quicprobe(config)

  defp run_topology(%{topology: @moqx_client_topology} = config), do: run_moqx_client(config)

  defp run_quicprobe(config) do
    args = quicprobe_args(config)
    timeout_ms = step_timeout_ms(config)
    {output, status, timed_out?} = run_command(config.quicprobe_command, args, timeout_ms)
    measurement = decode_json(output)

    {measurement, output, status, [config.quicprobe_command | args], timed_out?, timeout_ms}
  end

  defp quicprobe_args(config) do
    args =
      [
        "client",
        "--addr",
        "#{config.server}:#{config.port}",
        "--ca",
        config.ca,
        "--alpn",
        config.alpn,
        "--json",
        "--workload",
        config.workload,
        "--stream-direction",
        config.stream_direction,
        "--stream-count",
        Integer.to_string(config.stream_count),
        "--payload-size",
        Integer.to_string(config.payload_size),
        "--payload-count",
        Integer.to_string(config.payload_count),
        "--datagram-size",
        Integer.to_string(config.datagram_size),
        "--timeout",
        "#{datagram_client_timeout_seconds(config)}s"
      ]
      |> append_datagram_args(config)
      |> append_mixed_args(config)

    if config.servername do
      args ++ ["--servername", config.servername]
    else
      args
    end
  end

  defp run_moqx_client(config) do
    args = moqx_client_step_args(config)
    timeout_ms = step_timeout_ms(config)

    task =
      Task.async(fn ->
        do_run_moqx_client(config)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, measurement}} ->
        {measurement, "", 0, args, false, timeout_ms}

      {:ok, {:error, message}} ->
        {diagnostic_measurement(config), message, 1, args, false, timeout_ms}

      nil ->
        measurement = diagnostic_measurement(config)
        _result = Task.shutdown(task, :brutal_kill)
        {measurement, "", @timeout_exit_status, args, true, timeout_ms}
    end
  end

  defp moqx_client_step_args(config) do
    [
      "moqx-client",
      "--addr",
      "#{config.server}:#{config.port}",
      "--ca",
      config.ca,
      "--alpn",
      config.alpn,
      "--workload",
      config.workload,
      "--stream-direction",
      config.stream_direction,
      "--stream-count",
      Integer.to_string(config.stream_count),
      "--stream-send-window",
      Integer.to_string(config.stream_send_window),
      "--stream-event-batch-size",
      Integer.to_string(config.stream_event_batch_size),
      "--stream-diagnostics-sampling",
      config.stream_diagnostics_sampling,
      "--payload-size",
      Integer.to_string(config.payload_size),
      "--payload-count",
      Integer.to_string(config.payload_count),
      "--datagram-size",
      Integer.to_string(config.datagram_size),
      "--timeout",
      "#{datagram_client_timeout_seconds(config)}s"
    ]
    |> append_datagram_args(config)
    |> append_mixed_args(config)
    |> maybe_append_servername(config.servername)
  end

  defp append_datagram_args(args, %{workload: @datagram_pressure_workload} = config) do
    args =
      args ++
        [
          "--datagram-count",
          Integer.to_string(config.datagram_count)
        ]

    if paced_datagrams?(config) do
      args ++
        [
          "--datagram-rate",
          Integer.to_string(config.datagram_rate),
          "--duration-seconds",
          Integer.to_string(config.duration_seconds),
          "--offered-rate-tolerance",
          Float.to_string(config.offered_rate_tolerance)
        ]
    else
      args
    end
  end

  defp append_datagram_args(args, _config) do
    args ++
      [
        "--datagram-count",
        "1000"
      ]
  end

  defp append_mixed_args(args, %{workload: @mixed_moqt_shaped_workload} = config) do
    args ++
      [
        "--control-payload-size",
        Integer.to_string(config.control_payload_size),
        "--control-message-count",
        Integer.to_string(config.control_message_count),
        "--control-rate",
        Integer.to_string(config.control_rate)
      ]
  end

  defp append_mixed_args(args, _config), do: args

  defp do_run_moqx_client(config) do
    {:ok, ctx} = Transport.new(config.transport_backend)
    connect_started_at = monotonic_us()

    case Transport.connect(
           ctx,
           config.server,
           config.port,
           connect_opts(config),
           client_timeout_ms(config)
         ) do
      {:ok, connection, ctx} ->
        handshake_latency_ms = elapsed_ms(connect_started_at)
        record_diagnostics_summary(config, %{"handshake_latency_ms" => handshake_latency_ms})

        try do
          {:ok, measure_moqx_workload(ctx, connection, config, handshake_latency_ms)}
        after
          _result = Transport.close_connection(ctx, connection, 0)
        end

      {:error, reason, _ctx} ->
        {:error, inspect(reason)}
    end
  rescue
    exception ->
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp diagnostic_measurement(config), do: diagnostic_measurement(config, %{})

  defp diagnostic_measurement(config, diagnostics) do
    summary = Map.get(diagnostics, "summary", %{})

    %{
      "schema_version" => "moqx-reference-measurement-v1",
      "record_type" => "client_run",
      "tool" => "moqx-transport-bench",
      "client_implementation" => "moqx",
      "reference_implementation" => "quicprobe",
      "reference_version" => nil,
      "alpn" => config.alpn,
      "workload" => config.workload,
      "stream_direction" => config.stream_direction,
      "stream_count" => config.stream_count,
      "stream_send_window" => config.stream_send_window,
      "stream_event_batch_size" => config.stream_event_batch_size,
      "stream_diagnostics_sampling" => config.stream_diagnostics_sampling,
      "payload_size_bytes" => config.payload_size,
      "payload_count" => config.payload_count,
      "bytes_sent" => Map.get(summary, "bytes_sent"),
      "bytes_received" => Map.get(summary, "bytes_received"),
      "handshake_latency_ms" => Map.get(summary, "handshake_latency_ms"),
      "first_byte_latency_ms" => nil,
      "application_duration_ms" => Map.get(summary, "application_duration_ms"),
      "goodput_bps" => nil,
      "stream_latency_ms" => %{"p50" => nil, "p95" => nil, "p99" => nil},
      "send_rate_packets_per_second" => nil,
      "stream_scheduling" => "concurrent",
      "stream_failure" => Map.get(summary, "failure"),
      "diagnostics" =>
        diagnostics
        |> Map.put("process", process_diagnostics())
        |> diagnostics_stream_list()
    }
  end

  defp diagnostics_stream_list(%{"streams" => streams} = diagnostics) when is_map(streams) do
    Map.put(diagnostics, "streams", streams |> Map.values() |> Enum.sort_by(& &1["index"]))
  end

  defp diagnostics_stream_list(diagnostics), do: diagnostics

  defp record_diagnostics_summary(_config, _summary), do: :ok

  defp record_stream_phase(config, stream_state, phase, attrs \\ %{})

  defp record_stream_phase(_config, _stream_state, _phase, _attrs), do: :ok

  defp record_scheduled_streams(config, streams, payload) do
    expected_bytes = byte_size(payload) * config.payload_count

    Enum.each(streams, fn stream_state ->
      record_stream_phase(config, stream_state, "send_fin_scheduled", %{
        "bytes_expected" => expected_bytes
      })
    end)
  end

  defp process_diagnostics(process_samples \\ %{}) do
    current = message_queue_len()

    peak =
      [current, Map.get(process_samples, "message_queue_len_peak")]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    compact(%{
      "message_queue_len" => current,
      "message_queue_len_peak" => peak,
      "message_queue_len_samples" => Map.get(process_samples, "message_queue_len_samples"),
      "message_queue_len_sample_points" =>
        Map.get(process_samples, "message_queue_len_sample_points")
    })
  end

  defp message_queue_len do
    message_queue_len =
      case Process.info(self(), :message_queue_len) do
        {:message_queue_len, value} -> value
        nil -> nil
      end

    message_queue_len
  end

  defp sample_process_diagnostics(%{process: process} = state) do
    %{state | process: sample_process_diagnostics(process)}
  end

  defp sample_process_diagnostics(process) when is_map(process) do
    message_queue_len = message_queue_len()
    sample_index = Map.get(process, "message_queue_len_samples", 0) + 1

    process
    |> Map.put("message_queue_len", message_queue_len)
    |> Map.update("message_queue_len_peak", message_queue_len, fn
      nil -> message_queue_len
      peak -> max(peak, message_queue_len || 0)
    end)
    |> Map.put("message_queue_len_samples", sample_index)
    |> maybe_append_message_queue_sample(sample_index, message_queue_len)
  end

  defp maybe_append_message_queue_sample(process, sample_index, message_queue_len) do
    if keep_message_queue_sample?(sample_index) do
      point =
        compact(%{
          "sample_index" => sample_index,
          "elapsed_ms" => sample_elapsed_ms(process),
          "message_queue_len" => message_queue_len
        })

      Map.update(process, "message_queue_len_sample_points", [point], &(&1 ++ [point]))
    else
      process
    end
  end

  defp keep_message_queue_sample?(sample_index) do
    sample_index <= @message_queue_sample_prefix_count or
      rem(sample_index, @message_queue_sample_stride) == 0
  end

  defp sample_elapsed_ms(%{"started_at_us" => started_at}), do: elapsed_ms(started_at)
  defp sample_elapsed_ms(_process), do: nil

  defp connect_opts(config) do
    [
      alpn: config.alpn,
      cacertfile: config.ca,
      verify: :verify_peer,
      peer_bidi_stream_count: max(config.stream_count + 2, 10),
      peer_unidi_stream_count: max(config.stream_count + 2, 10)
    ]
    |> Kernel.++(datagram_opts(config))
    |> maybe_put_server_name(config.servername)
  end

  defp datagram_opts(%{workload: @datagram_pressure_workload}), do: [datagram_receive_enabled: 1]
  defp datagram_opts(_config), do: []

  defp maybe_put_server_name(opts, nil), do: opts
  defp maybe_put_server_name(opts, servername), do: Keyword.put(opts, :server_name, servername)

  defp client_timeout_ms(config), do: config.timeout_seconds * 1000

  defp step_timeout_ms(config) do
    (datagram_client_timeout_seconds(config) + config.timeout_margin_seconds) * 1000
  end

  defp datagram_client_timeout_seconds(%{workload: @datagram_pressure_workload} = config) do
    config.timeout_seconds + (config.duration_seconds || 0)
  end

  defp datagram_client_timeout_seconds(config), do: config.timeout_seconds

  defp measure_moqx_workload(
         ctx,
         connection,
         %{workload: @stream_pressure_workload} = config,
         latency
       ) do
    measure_moqx_stream_pressure(ctx, connection, config, latency)
  end

  defp measure_moqx_workload(
         ctx,
         connection,
         %{workload: @datagram_pressure_workload} = config,
         latency
       ) do
    measure_moqx_datagram_pressure(ctx, connection, config, latency)
  end

  defp measure_moqx_workload(
         ctx,
         connection,
         %{workload: @mixed_moqt_shaped_workload} = config,
         latency
       ) do
    measure_moqx_mixed_pressure(ctx, connection, config, latency)
  end

  defp measure_moqx_stream_pressure(ctx, connection, config, handshake_latency_ms) do
    {:ok, collector} =
      StreamPressureCollector.start(sample_process?: stream_pressure_process_sampling?(config))

    try do
      do_measure_moqx_stream_pressure(ctx, connection, config, handshake_latency_ms, collector)
    after
      StreamPressureCollector.close(collector)
    end
  end

  defp do_measure_moqx_stream_pressure(ctx, connection, config, handshake_latency_ms, collector) do
    application_started_at = monotonic_us()
    payload = binary_payload(config.payload_size)

    {streams, ctx} = open_pressure_streams(ctx, connection, config)

    {result, _ctx} =
      if config.stream_direction == "bidirectional" do
        collect_pressure_streams(ctx, streams, payload, config, application_started_at)
      else
        {streams, ctx} = schedule_pressure_payloads(ctx, streams, payload, config)
        record_scheduled_streams(config, streams, payload)
        collect_pressure_streams(ctx, streams, payload, config, application_started_at)
      end

    result =
      if config.stream_direction == "bidirectional",
        do: result,
        else: %{result | bytes_sent: Enum.sum(Enum.map(streams, & &1.bytes_sent))}

    collector_snapshot = StreamPressureCollector.snapshot(collector)
    result = apply_stream_pressure_collector(result, collector_snapshot)
    application_duration_ms = elapsed_ms(application_started_at)
    first_byte_latency_ms = result.first_byte_latency_ms

    bytes_for_goodput =
      if config.stream_direction == "unidirectional",
        do: result.bytes_sent,
        else: result.bytes_received

    %{
      "schema_version" => "moqx-reference-measurement-v1",
      "record_type" => "client_run",
      "tool" => "moqx-transport-bench",
      "client_implementation" => "moqx",
      "reference_implementation" => "quicprobe",
      "reference_version" => nil,
      "alpn" => config.alpn,
      "stream_direction" => config.stream_direction,
      "stream_count" => config.stream_count,
      "stream_send_window" => config.stream_send_window,
      "stream_event_batch_size" => config.stream_event_batch_size,
      "stream_diagnostics_sampling" => config.stream_diagnostics_sampling,
      "payload_size_bytes" => config.payload_size,
      "payload_count" => config.payload_count,
      "bytes_sent" => result.bytes_sent,
      "bytes_received" => result.bytes_received,
      "handshake_latency_ms" => handshake_latency_ms,
      "first_byte_latency_ms" => first_byte_latency_ms,
      "application_duration_ms" => application_duration_ms,
      "goodput_bps" => bits_per_second(bytes_for_goodput, application_duration_ms),
      "stream_latency_ms" => latency_summary(result.stream_latencies_ms),
      "send_stream_call_ms" => duration_summary_ms(result.send_stream_call_durations_us),
      "send_rate_packets_per_second" =>
        rate(config.stream_count * config.payload_count, seconds(application_duration_ms)),
      "stream_scheduling" => "concurrent",
      "stream_failure" => result.failure,
      "diagnostics" =>
        stream_pressure_diagnostics(config, streams, result, application_duration_ms)
    }
  end

  defp stream_pressure_process_sampling?(%{stream_diagnostics_sampling: "final"}), do: false
  defp stream_pressure_process_sampling?(_config), do: true

  defp apply_stream_pressure_collector(result, snapshot) do
    result
    |> Map.put(:send_stream_call_durations_us, snapshot.send_stream_call_durations_us)
    |> Map.put(:stream_send_accepted, snapshot.stream_send_accepted)
    |> Map.put(:stream_send_bytes_accepted, snapshot.stream_send_bytes_accepted)
    |> Map.put(:stream_send_errors, snapshot.stream_send_errors)
    |> Map.put(
      :runtime_diagnostics,
      merge_runtime_diagnostics(
        Map.get(result, :runtime_diagnostics, %{}),
        snapshot.runtime_diagnostics
      )
    )
  end

  defp merge_runtime_diagnostics(base, collected) do
    Map.merge(base, collected, &merge_runtime_diagnostic/3)
  end

  defp merge_runtime_diagnostic(:process, base, collected)
       when is_map(base) and is_map(collected) do
    Map.merge(base, collected)
  end

  defp merge_runtime_diagnostic(_key, base, collected)
       when is_integer(base) and is_integer(collected) do
    max(base, collected)
  end

  defp merge_runtime_diagnostic(_key, _base, collected), do: collected

  defp measure_moqx_datagram_pressure(ctx, connection, config, handshake_latency_ms) do
    application_started_at = monotonic_us()
    offered = effective_datagram_count(config)

    case send_and_receive_moqx_datagrams(ctx, connection, config, offered, application_started_at) do
      {:ok, accepted, send_duration_ms, receive_state, _ctx} ->
        datagram_measurement(%{
          config: config,
          handshake_latency_ms: handshake_latency_ms,
          application_started_at: application_started_at,
          offered: offered,
          accepted: accepted,
          send_duration_ms: send_duration_ms,
          receive_state: receive_state
        })

      {:error, failure, accepted, send_duration_ms, receive_state, _ctx} ->
        datagram_measurement(%{
          config: config,
          handshake_latency_ms: handshake_latency_ms,
          application_started_at: application_started_at,
          offered: offered,
          accepted: accepted,
          send_duration_ms: send_duration_ms,
          receive_state: receive_state,
          failure: failure
        })
    end
  end

  defp datagram_measurement(args) do
    config = args.config
    failure = Map.get(args, :failure)
    receive_state = args.receive_state
    received_count = MapSet.size(receive_state.received)
    application_duration_ms = elapsed_ms(args.application_started_at)
    bytes_sent = args.accepted * config.datagram_size
    bytes_received = received_count * config.datagram_size
    send_rate = rate(args.accepted, seconds(args.send_duration_ms))
    offered_rate_ratio = target_rate_ratio(send_rate, config)

    %{
      "schema_version" => "moqx-reference-measurement-v1",
      "record_type" => "client_run",
      "tool" => "moqx-transport-bench",
      "client_implementation" => "moqx",
      "reference_implementation" => "quicprobe",
      "reference_version" => nil,
      "alpn" => config.alpn,
      "workload" => @datagram_pressure_workload,
      "payload_size_bytes" => config.datagram_size,
      "datagram_size_bytes" => config.datagram_size,
      "datagram_count" => args.offered,
      "datagram_mode" => datagram_mode(config),
      "target_datagrams_per_second" => target_datagram_rate(config),
      "target_duration_seconds" => target_duration_seconds(config),
      "delivery_threshold" => config.delivery_threshold,
      "offered_rate_ratio" => offered_rate_ratio,
      "offered_rate_tolerance" => config.offered_rate_tolerance,
      "offered_rate_valid" => offered_rate_valid?(offered_rate_ratio, config),
      "datagrams_offered" => args.offered,
      "datagrams_accepted" => args.accepted,
      "datagrams_received" => received_count,
      "datagram_delivery_ratio" => ratio(received_count, args.offered),
      "datagram_drop_count" => args.offered - received_count,
      "bytes_sent" => bytes_sent,
      "bytes_received" => bytes_received,
      "handshake_latency_ms" => args.handshake_latency_ms,
      "first_byte_latency_ms" => receive_state.first_byte_latency_ms,
      "application_duration_ms" => application_duration_ms,
      "offered_load_bps" => offered_load_bps(config),
      "goodput_bps" => bits_per_second(bytes_received, application_duration_ms),
      "send_rate_packets_per_second" => send_rate,
      "send_rate_datagrams_per_second" => send_rate,
      "datagram_latency_ms" => latency_summary(receive_state.latencies),
      "datagram_failure" => failure,
      "diagnostics" =>
        datagram_pressure_diagnostics(
          config,
          args,
          receive_state,
          received_count,
          application_duration_ms
        )
    }
  end

  defp measure_moqx_mixed_pressure(ctx, connection, config, handshake_latency_ms) do
    application_started_at = monotonic_us()
    object_config = %{config | stream_direction: "unidirectional"}
    object_payload = binary_payload(config.payload_size)
    control_payload = binary_payload(config.control_payload_size)

    {object_streams, ctx} = open_pressure_streams(ctx, connection, object_config)

    {state, _ctx} =
      case Transport.open_stream(ctx, connection, direction: :bidirectional, active: true) do
        {:ok, control_stream, ctx} ->
          object_streams
          |> initial_mixed_pressure_state(control_stream)
          |> run_mixed_event_pump(
            ctx,
            object_payload,
            object_config,
            control_payload,
            config,
            application_started_at
          )

        {:error, reason, ctx} ->
          failure = mixed_control_failure(config, "open_control_stream", reason, 0, 0)
          {failed_initial_mixed_pressure_state(object_streams, failure), ctx}
      end

    application_duration_ms = elapsed_ms(application_started_at)
    object_bytes_sent = mixed_object_bytes_sent(state)
    control_result = mixed_control_result(state.control)
    bytes_sent = object_bytes_sent + control_result.bytes_sent

    %{
      "schema_version" => "moqx-reference-measurement-v1",
      "record_type" => "client_run",
      "tool" => "moqx-transport-bench",
      "client_implementation" => "moqx",
      "reference_implementation" => "quicprobe",
      "reference_version" => nil,
      "alpn" => config.alpn,
      "workload" => @mixed_moqt_shaped_workload,
      "stream_direction" => "mixed",
      "stream_count" => config.stream_count,
      "payload_size_bytes" => config.payload_size,
      "payload_count" => config.payload_count,
      "control_payload_size_bytes" => config.control_payload_size,
      "control_message_count" => config.control_message_count,
      "control_messages_per_second" => config.control_rate * 1.0,
      "control_trickle_bps" => control_trickle_bps(config),
      "bytes_sent" => bytes_sent,
      "bytes_received" => control_result.bytes_received,
      "handshake_latency_ms" => handshake_latency_ms,
      "first_byte_latency_ms" => control_result.first_byte_latency_ms,
      "application_duration_ms" => application_duration_ms,
      "goodput_bps" => bits_per_second(bytes_sent, application_duration_ms),
      "send_rate_packets_per_second" =>
        rate(
          config.stream_count * config.payload_count + config.control_message_count,
          seconds(application_duration_ms)
        ),
      "stream_scheduling" => "mixed_control_bidi_object_uni",
      "stream_latency_ms" => latency_summary(mixed_object_stream_latencies(state)),
      "control_latency_ms" => latency_summary(control_result.latencies),
      "stream_failure" => control_result.failure,
      "diagnostics" =>
        mixed_pressure_diagnostics(
          config,
          state,
          control_result,
          object_bytes_sent,
          application_duration_ms
        )
    }
  end

  defp initial_mixed_pressure_state(object_streams, control_stream) do
    %{
      object_streams:
        Map.new(object_streams, fn stream_state ->
          {stream_state.stream,
           %{
             stream_state: stream_state,
             payloads_scheduled: 0,
             payloads_completed: 0,
             send_inflight: 0,
             send_completed: 0,
             send_cancelled: 0,
             completed_at: nil,
             failure: nil
           }}
        end),
      control: initial_mixed_control_state(control_stream),
      process: %{},
      events_drained: 0,
      ignored_events: 0,
      unknown_events: 0,
      receive_errors: 0,
      object_send_events: 0,
      control_send_events: 0,
      control_data_events: 0,
      completion_drain_events: 0
    }
  end

  defp failed_initial_mixed_pressure_state(object_streams, failure) do
    object_streams
    |> initial_mixed_pressure_state(nil)
    |> put_in([:control, :failure], failure)
  end

  defp initial_mixed_control_state(stream) do
    %{
      stream: stream,
      bytes_sent: 0,
      bytes_received: 0,
      first_byte_latency_ms: nil,
      latencies: [],
      sent_at_by_sequence: %{},
      messages_scheduled: 0,
      messages_echoed: 0,
      send_inflight: 0,
      send_completed: 0,
      send_cancelled: 0,
      failure: nil
    }
  end

  defp run_mixed_event_pump(
         state,
         ctx,
         object_payload,
         object_config,
         control_payload,
         config,
         application_started_at
       ) do
    deadline_us = application_started_at + client_timeout_ms(config) * 1000

    state
    |> sample_process_diagnostics()
    |> collect_mixed_events(
      ctx,
      object_payload,
      object_config,
      control_payload,
      config,
      application_started_at,
      deadline_us
    )
  end

  defp collect_mixed_events(
         state,
         ctx,
         object_payload,
         object_config,
         control_payload,
         config,
         application_started_at,
         deadline_us
       ) do
    {state, ctx} = schedule_mixed_object_sends(state, ctx, object_payload, object_config)

    {state, ctx} =
      maybe_schedule_mixed_control(state, ctx, control_payload, config, application_started_at)

    state = sample_process_diagnostics(state)

    cond do
      mixed_complete?(state, config) ->
        state
        |> drain_mixed_residual_events(
          ctx,
          object_payload,
          object_config,
          control_payload,
          config,
          application_started_at,
          @mixed_completion_drain_limit
        )
        |> then(fn {state, ctx} -> {sample_process_diagnostics(state), ctx} end)

      failure = first_mixed_failure(state) ->
        {put_mixed_failure(state, failure), ctx}

      monotonic_us() >= deadline_us ->
        failure = mixed_timeout_failure(state, config)
        {put_mixed_failure(state, failure), ctx}

      true ->
        timeout_ms = mixed_event_timeout_ms(state, config, application_started_at, deadline_us)

        case Transport.receive_event(ctx, timeout_ms) do
          {:ok, event, ctx} ->
            state =
              state
              |> handle_mixed_event(
                event,
                object_payload,
                object_config,
                control_payload,
                config,
                application_started_at
              )
              |> sample_process_diagnostics()

            collect_mixed_events(
              state,
              ctx,
              object_payload,
              object_config,
              control_payload,
              config,
              application_started_at,
              deadline_us
            )

          {:unknown, _message, ctx} ->
            state =
              state
              |> Map.update!(:unknown_events, &(&1 + 1))
              |> sample_process_diagnostics()

            collect_mixed_events(
              state,
              ctx,
              object_payload,
              object_config,
              control_payload,
              config,
              application_started_at,
              deadline_us
            )

          {:error, _reason, ctx} ->
            state =
              state
              |> Map.update!(:receive_errors, &(&1 + 1))
              |> sample_process_diagnostics()

            collect_mixed_events(
              state,
              ctx,
              object_payload,
              object_config,
              control_payload,
              config,
              application_started_at,
              deadline_us
            )

          {:timeout, ctx} ->
            collect_mixed_events(
              sample_process_diagnostics(state),
              ctx,
              object_payload,
              object_config,
              control_payload,
              config,
              application_started_at,
              deadline_us
            )
        end
    end
  end

  defp drain_mixed_residual_events(
         state,
         ctx,
         object_payload,
         object_config,
         control_payload,
         config,
         application_started_at,
         limit
       )

  defp drain_mixed_residual_events(
         state,
         ctx,
         _object_payload,
         _object_config,
         _control_payload,
         _config,
         _application_started_at,
         limit
       )
       when limit <= 0 do
    {state, ctx}
  end

  defp drain_mixed_residual_events(
         state,
         ctx,
         object_payload,
         object_config,
         control_payload,
         config,
         application_started_at,
         limit
       ) do
    case Transport.receive_event(ctx, 0) do
      {:ok, event, ctx} ->
        state =
          state
          |> handle_mixed_event(
            event,
            object_payload,
            object_config,
            control_payload,
            config,
            application_started_at
          )
          |> Map.update!(:completion_drain_events, &(&1 + 1))
          |> sample_process_diagnostics()

        drain_mixed_residual_events(
          state,
          ctx,
          object_payload,
          object_config,
          control_payload,
          config,
          application_started_at,
          limit - 1
        )

      {:unknown, _message, ctx} ->
        state =
          state
          |> Map.update!(:unknown_events, &(&1 + 1))
          |> Map.update!(:completion_drain_events, &(&1 + 1))
          |> sample_process_diagnostics()

        drain_mixed_residual_events(
          state,
          ctx,
          object_payload,
          object_config,
          control_payload,
          config,
          application_started_at,
          limit - 1
        )

      {:error, _reason, ctx} ->
        state =
          state
          |> Map.update!(:receive_errors, &(&1 + 1))
          |> Map.update!(:completion_drain_events, &(&1 + 1))
          |> sample_process_diagnostics()

        drain_mixed_residual_events(
          state,
          ctx,
          object_payload,
          object_config,
          control_payload,
          config,
          application_started_at,
          limit - 1
        )

      {:timeout, ctx} ->
        {state, ctx}
    end
  end

  defp schedule_mixed_object_sends(state, ctx, payload, config) do
    Enum.reduce(state.object_streams, {state, ctx}, fn {stream, object}, {state, ctx} ->
      {object, ctx} = schedule_mixed_object_stream_sends(object, ctx, payload, config)
      {%{state | object_streams: Map.put(state.object_streams, stream, object)}, ctx}
    end)
  end

  defp schedule_mixed_object_stream_sends(object, ctx, payload, config) do
    cond do
      object.failure ->
        {object, ctx}

      object.payloads_scheduled >= config.payload_count ->
        {object, ctx}

      object.send_inflight >= config.stream_send_window ->
        {object, ctx}

      true ->
        payload_index = object.payloads_scheduled + 1
        finish? = payload_index == config.payload_count
        opts = if finish?, do: [finish: true], else: []

        case Transport.send_stream(ctx, object.stream_state.stream, payload, opts) do
          {:ok, _send, ctx} ->
            stream_state = %{
              object.stream_state
              | bytes_sent: object.stream_state.bytes_sent + byte_size(payload),
                payloads_accepted: object.stream_state.payloads_accepted + 1
            }

            object = %{
              object
              | stream_state: stream_state,
                payloads_scheduled: payload_index,
                send_inflight: object.send_inflight + 1
            }

            record_stream_phase(config, stream_state, "mixed_object_send_window_open", %{
              "bytes_expected" => expected_stream_bytes(config),
              "payloads_scheduled" => object.payloads_scheduled,
              "send_inflight" => object.send_inflight,
              "send_window" => config.stream_send_window
            })

            schedule_mixed_object_stream_sends(object, ctx, payload, config)

          {:error, reason, ctx} ->
            {%{object | failure: mixed_object_failure(object, config, reason_name(reason))}, ctx}
        end
    end
  end

  defp maybe_schedule_mixed_control(state, ctx, payload, config, application_started_at) do
    if mixed_control_ready_to_send?(state.control, config, application_started_at) do
      schedule_mixed_control_message(state, ctx, payload, config)
    else
      {state, ctx}
    end
  end

  defp mixed_control_ready_to_send?(control, config, application_started_at) do
    cond do
      is_nil(control.stream) ->
        false

      control.failure ->
        false

      control.messages_scheduled >= config.control_message_count ->
        false

      control.messages_echoed < control.messages_scheduled ->
        false

      true ->
        monotonic_us() >=
          mixed_control_due_us(control.messages_scheduled + 1, config, application_started_at)
    end
  end

  defp schedule_mixed_control_message(state, ctx, payload, config) do
    control = state.control
    sequence = control.messages_scheduled + 1
    opts = if sequence == config.control_message_count, do: [finish: true], else: []
    sent_at = monotonic_us()

    case Transport.send_stream(ctx, control.stream, payload, opts) do
      {:ok, _send, ctx} ->
        control = %{
          control
          | bytes_sent: control.bytes_sent + byte_size(payload),
            messages_scheduled: sequence,
            send_inflight: control.send_inflight + 1,
            sent_at_by_sequence: Map.put(control.sent_at_by_sequence, sequence, sent_at)
        }

        {%{state | control: control}, ctx}

      {:error, reason, ctx} ->
        failure =
          mixed_control_failure(
            config,
            "send_control_message",
            reason,
            sequence,
            control.bytes_received
          )

        {%{state | control: %{control | failure: failure}}, ctx}
    end
  end

  defp mixed_control_due_us(sequence, config, application_started_at) do
    interval_us = div(1_000_000, config.control_rate)
    application_started_at + (sequence - 1) * interval_us
  end

  defp mixed_event_timeout_ms(state, config, application_started_at, deadline_us) do
    now = monotonic_us()
    deadline_ms = max(div(deadline_us - now, 1000), 0)

    next_control_ms =
      case next_mixed_control_due_us(state, config, application_started_at) do
        nil -> deadline_ms
        due_us -> max(div(due_us - now, 1000), 0)
      end

    min(deadline_ms, max(next_control_ms, 1))
  end

  defp next_mixed_control_due_us(state, config, application_started_at) do
    control = state.control

    cond do
      is_nil(control.stream) -> nil
      control.failure -> nil
      control.messages_scheduled >= config.control_message_count -> nil
      control.messages_echoed < control.messages_scheduled -> nil
      true -> mixed_control_due_us(control.messages_scheduled + 1, config, application_started_at)
    end
  end

  defp handle_mixed_event(
         state,
         event,
         object_payload,
         object_config,
         control_payload,
         config,
         started_at
       ) do
    state = Map.update!(state, :events_drained, &(&1 + 1))

    case event do
      {:stream_event, stream, :send_completed, _metadata} ->
        handle_mixed_send_completion(state, stream, object_config)

      {:stream_event, stream, :send_cancelled, _metadata} ->
        handle_mixed_send_cancelled(state, stream, object_config, config)

      {:stream_data, stream, data, _metadata} ->
        handle_mixed_stream_data(
          state,
          stream,
          data,
          object_payload,
          control_payload,
          config,
          started_at
        )

      {:stream_event, stream, :peer_finished_sending, _metadata} ->
        handle_mixed_peer_finished(state, stream, config)

      {:stream_event, stream, :closed, _metadata} ->
        handle_mixed_peer_finished(state, stream, config)

      _event ->
        Map.update!(state, :ignored_events, &(&1 + 1))
    end
  end

  defp handle_mixed_send_completion(state, stream, object_config) do
    cond do
      Map.has_key?(state.object_streams, stream) ->
        state
        |> update_in([:object_streams, stream], &complete_mixed_object_send(&1, object_config))
        |> Map.update!(:object_send_events, &(&1 + 1))

      state.control.stream == stream ->
        state
        |> update_in([:control], fn control ->
          %{
            control
            | send_completed: control.send_completed + 1,
              send_inflight: max(control.send_inflight - 1, 0)
          }
        end)
        |> Map.update!(:control_send_events, &(&1 + 1))

      true ->
        Map.update!(state, :ignored_events, &(&1 + 1))
    end
  end

  defp complete_mixed_object_send(object, config) do
    payloads_completed = object.payloads_completed + 1
    completed_at = if payloads_completed >= config.payload_count, do: monotonic_us()

    object = %{
      object
      | payloads_completed: payloads_completed,
        send_completed: object.send_completed + 1,
        send_inflight: max(object.send_inflight - 1, 0),
        completed_at: completed_at || object.completed_at
    }

    record_stream_phase(config, object.stream_state, mixed_object_send_phase(object, config), %{
      "bytes_expected" => expected_stream_bytes(config),
      "payloads_scheduled" => object.payloads_scheduled,
      "payloads_completed" => object.payloads_completed,
      "send_inflight" => object.send_inflight,
      "send_completions_pending" => object.payloads_scheduled - object.payloads_completed
    })

    object
  end

  defp mixed_object_send_phase(object, config) do
    if object.payloads_completed >= config.payload_count,
      do: "mixed_object_send_complete",
      else: "mixed_object_sending"
  end

  defp handle_mixed_send_cancelled(state, stream, object_config, config) do
    cond do
      Map.has_key?(state.object_streams, stream) ->
        state
        |> update_in([:object_streams, stream], fn object ->
          object = %{
            object
            | send_cancelled: object.send_cancelled + 1,
              send_inflight: max(object.send_inflight - 1, 0)
          }

          %{object | failure: mixed_object_failure(object, object_config, "send_cancelled")}
        end)
        |> Map.update!(:object_send_events, &(&1 + 1))

      state.control.stream == stream ->
        failure =
          mixed_control_failure(
            config,
            "send_control_message",
            :send_cancelled,
            state.control.messages_scheduled,
            state.control.bytes_received
          )

        state
        |> put_in([:control, :failure], failure)
        |> update_in([:control, :send_cancelled], &(&1 + 1))
        |> update_in([:control, :send_inflight], &max(&1 - 1, 0))
        |> Map.update!(:control_send_events, &(&1 + 1))

      true ->
        Map.update!(state, :ignored_events, &(&1 + 1))
    end
  end

  defp handle_mixed_stream_data(
         state,
         stream,
         data,
         _object_payload,
         control_payload,
         config,
         started_at
       ) do
    if state.control.stream == stream do
      state
      |> update_in([:control], fn control ->
        handle_mixed_control_data(control, data, control_payload, config, started_at)
      end)
      |> Map.update!(:control_data_events, &(&1 + 1))
    else
      Map.update!(state, :ignored_events, &(&1 + 1))
    end
  end

  defp handle_mixed_control_data(control, data, payload, config, started_at) do
    received_before = control.bytes_received

    if matches_payload?(data, payload, received_before) do
      bytes_received = received_before + byte_size(data)
      messages_echoed = min(div(bytes_received, byte_size(payload)), config.control_message_count)

      %{
        control
        | bytes_received: bytes_received,
          first_byte_latency_ms: control.first_byte_latency_ms || elapsed_ms(started_at),
          messages_echoed: messages_echoed,
          latencies: mixed_control_latencies(control, messages_echoed)
      }
    else
      failure =
        mixed_control_failure(
          config,
          "receive_control_echo",
          :echo_payload_mismatch,
          control.messages_echoed + 1,
          received_before + byte_size(data)
        )

      %{control | failure: failure}
    end
  end

  defp mixed_control_latencies(control, messages_echoed) do
    if messages_echoed > control.messages_echoed do
      new_latencies =
        (control.messages_echoed + 1)..messages_echoed
        |> Enum.map(fn sequence ->
          control.sent_at_by_sequence
          |> Map.fetch!(sequence)
          |> elapsed_ms()
        end)

      new_latencies ++ control.latencies
    else
      control.latencies
    end
  end

  defp handle_mixed_peer_finished(state, stream, config) do
    if state.control.stream == stream and
         state.control.bytes_received < config.control_payload_size * config.control_message_count do
      failure =
        mixed_control_failure(
          config,
          "receive_control_echo",
          :peer_send_shutdown,
          state.control.messages_echoed + 1,
          state.control.bytes_received
        )

      put_in(state, [:control, :failure], failure)
    else
      Map.update!(state, :ignored_events, &(&1 + 1))
    end
  end

  defp mixed_complete?(state, config) do
    mixed_objects_complete?(state, config) and mixed_control_complete?(state, config)
  end

  defp mixed_objects_complete?(state, config) do
    Enum.all?(state.object_streams, fn {_stream, object} ->
      object.payloads_completed >= config.payload_count
    end)
  end

  defp mixed_control_complete?(state, config) do
    control = state.control

    control.messages_echoed >= config.control_message_count and
      control.send_completed >= config.control_message_count
  end

  defp first_mixed_failure(state) do
    object_failure =
      state.object_streams
      |> Map.values()
      |> Enum.map(& &1.failure)
      |> Enum.find(&is_map/1)

    object_failure || state.control.failure
  end

  defp mixed_timeout_failure(state, config) do
    incomplete_object =
      state.object_streams
      |> Map.values()
      |> Enum.find(fn object -> object.payloads_completed < config.payload_count end)

    cond do
      incomplete_object ->
        mixed_object_failure(incomplete_object, config, "send_completion_timeout")

      state.control.messages_echoed < config.control_message_count ->
        mixed_control_failure(
          config,
          "receive_control_echo",
          :timeout,
          state.control.messages_echoed + 1,
          state.control.bytes_received
        )

      true ->
        mixed_control_failure(
          config,
          "send_control_message",
          :send_completion_timeout,
          state.control.messages_scheduled,
          state.control.bytes_received
        )
    end
  end

  defp put_mixed_failure(state, %{"stream_id" => "control"} = failure) do
    put_in(state, [:control, :failure], failure)
  end

  defp put_mixed_failure(state, %{"stream_index" => stream_index} = failure) do
    {stream, object} =
      Enum.find(state.object_streams, fn {_stream, object} ->
        object.stream_state.index == stream_index
      end)

    put_in(state, [:object_streams, stream], %{object | failure: failure})
  end

  defp mixed_control_failure(config, phase, reason, sequence, bytes_received) do
    %{
      "phase" => phase,
      "reason" => reason_name(reason),
      "stream_index" => 0,
      "stream_id" => "control",
      "control_message_sequence" => sequence,
      "bytes_expected" => config.control_payload_size * config.control_message_count,
      "bytes_received" => bytes_received,
      "incomplete_bytes" =>
        max(config.control_payload_size * config.control_message_count - bytes_received, 0)
    }
  end

  defp mixed_object_failure(object, config, reason) do
    %{
      "phase" => "mixed_object_send",
      "reason" => reason_name(reason),
      "stream_index" => object.stream_state.index,
      "stream_id" => stream_id(object.stream_state.stream),
      "bytes_expected" => config.payload_size * config.payload_count,
      "bytes_sent" => object.stream_state.bytes_sent,
      "payloads_scheduled" => object.payloads_scheduled,
      "payloads_completed" => object.payloads_completed,
      "send_completions_pending" => object.payloads_scheduled - object.payloads_completed
    }
  end

  defp mixed_control_result(control) do
    %{
      bytes_sent: control.bytes_sent,
      bytes_received: control.bytes_received,
      first_byte_latency_ms: control.first_byte_latency_ms,
      latencies: control.latencies,
      failure: control.failure
    }
  end

  defp mixed_object_bytes_sent(state) do
    state.object_streams
    |> Map.values()
    |> Enum.map(& &1.stream_state.bytes_sent)
    |> Enum.sum()
  end

  defp mixed_object_stream_latencies(state) do
    Enum.map(state.object_streams, fn {_stream, object} ->
      finished_at = object.completed_at || monotonic_us()
      (finished_at - object.stream_state.started_at) / 1000
    end)
  end

  defp mixed_pressure_diagnostics(
         config,
         state,
         control_result,
         object_bytes_sent,
         application_duration_ms
       ) do
    object_streams = Map.values(state.object_streams)
    process = process_diagnostics(state.process)

    %{
      "version" => "mixed-pressure-diagnostics-v1",
      "summary" =>
        compact(%{
          "object_streams_opened" => length(object_streams),
          "object_payloads_accepted" =>
            object_streams |> Enum.map(& &1.payloads_scheduled) |> Enum.sum(),
          "object_send_completions" =>
            object_streams |> Enum.map(& &1.payloads_completed) |> Enum.sum(),
          "object_send_completions_pending" =>
            object_streams
            |> Enum.map(&max(&1.payloads_scheduled - &1.payloads_completed, 0))
            |> Enum.sum(),
          "object_send_inflight" => object_streams |> Enum.map(& &1.send_inflight) |> Enum.sum(),
          "object_bytes_sent" => object_bytes_sent,
          "control_message_count" => config.control_message_count,
          "control_bytes_sent" => control_result.bytes_sent,
          "control_bytes_received" => control_result.bytes_received,
          "control_send_completions" => state.control.send_completed,
          "control_send_completions_pending" =>
            max(state.control.messages_scheduled - state.control.send_completed, 0),
          "events_drained" => state.events_drained,
          "object_send_events" => state.object_send_events,
          "control_send_events" => state.control_send_events,
          "control_data_events" => state.control_data_events,
          "completion_drain_events" => state.completion_drain_events,
          "ignored_events" => state.ignored_events,
          "unknown_events" => state.unknown_events,
          "receive_errors" => state.receive_errors,
          "application_duration_ms" => application_duration_ms,
          "failure" => control_result.failure
        }),
      "process" => process
    }
  end

  defp datagram_pressure_diagnostics(
         config,
         args,
         receive_state,
         received_count,
         application_duration_ms
       ) do
    failure = Map.get(args, :failure)

    %{
      "version" => "moqx-client-datagram-diagnostics-v1",
      "summary" =>
        compact(%{
          "datagrams_offered" => args.offered,
          "datagrams_accepted" => args.accepted,
          "datagrams_received" => received_count,
          "datagrams_missing" => max(args.offered - received_count, 0),
          "datagram_receive_events" => receive_state.datagram_receive_events,
          "duplicate_datagrams" => receive_state.duplicate_datagrams,
          "invalid_datagrams" => receive_state.invalid_datagrams,
          "ignored_events" => receive_state.ignored_events,
          "unknown_events" => receive_state.unknown_events,
          "receive_errors" => receive_state.receive_errors,
          "drain_events" => receive_state.drain_events,
          "application_duration_ms" => application_duration_ms,
          "target_datagrams_per_second" => target_datagram_rate(config),
          "send_error" => failure && failure["reason"]
        }),
      "process" => process_diagnostics(receive_state.process)
    }
  end

  defp send_and_receive_moqx_datagrams(
         ctx,
         connection,
         %{datagram_rate: rate} = config,
         count,
         started_at
       )
       when is_integer(rate) and rate > 0 do
    send_started_at = monotonic_us()
    interval_us = div(1_000_000, rate)
    receive_state = initial_moqx_datagram_receive_state()

    result =
      Enum.reduce_while(
        1..count,
        {0, ctx, receive_state, send_started_at},
        fn sequence, {accepted, ctx, receive_state, next_send_at} ->
          {receive_state, ctx} =
            receive_moqx_datagrams_until(
              ctx,
              connection,
              receive_state,
              started_at,
              next_send_at
            )

          case send_moqx_datagram(ctx, connection, config, sequence) do
            {:ok, ctx} ->
              {receive_state, ctx} =
                drain_available_moqx_datagrams(
                  ctx,
                  connection,
                  receive_state,
                  started_at
                )

              {:cont, {accepted + 1, ctx, receive_state, next_send_at + interval_us}}

            {:error, reason, ctx} ->
              failure = datagram_send_failure(config, reason, sequence, count, accepted)
              send_duration_ms = elapsed_ms(send_started_at)

              {:halt, {:error, failure, accepted, send_duration_ms, receive_state, ctx}}
          end
        end
      )

    case result do
      {:error, _failure, _accepted, _send_duration_ms, _receive_state, _ctx} = error ->
        error

      {accepted, ctx, receive_state, _next_send_at} ->
        send_duration_ms = elapsed_ms(send_started_at)

        {receive_state, ctx} =
          receive_moqx_datagrams(
            ctx,
            connection,
            config,
            count,
            receive_state,
            started_at
          )

        {:ok, accepted, send_duration_ms, receive_state, ctx}
    end
  end

  defp send_and_receive_moqx_datagrams(ctx, connection, config, count, started_at) do
    receive_state = initial_moqx_datagram_receive_state()

    case send_moqx_datagrams(ctx, connection, config, count) do
      {:ok, accepted, send_duration_ms, ctx} ->
        {receive_state, ctx} =
          receive_moqx_datagrams(
            ctx,
            connection,
            config,
            count,
            receive_state,
            started_at
          )

        {:ok, accepted, send_duration_ms, receive_state, ctx}

      {:error, failure, accepted, send_duration_ms, ctx} ->
        {:error, failure, accepted, send_duration_ms, receive_state, ctx}
    end
  end

  defp send_moqx_datagrams(ctx, connection, config, count) do
    started_at = monotonic_us()

    result =
      Enum.reduce_while(1..count, {0, ctx}, fn sequence, {accepted, ctx} ->
        case send_moqx_datagram(ctx, connection, config, sequence) do
          {:ok, ctx} ->
            {:cont, {accepted + 1, ctx}}

          {:error, reason, ctx} ->
            failure = datagram_send_failure(config, reason, sequence, count, accepted)
            {:halt, {:error, failure, accepted, elapsed_ms(started_at), ctx}}
        end
      end)

    case result do
      {:error, _failure, _accepted, _send_duration_ms, _ctx} = error ->
        error

      {accepted, ctx} ->
        {:ok, accepted, elapsed_ms(started_at), ctx}
    end
  end

  defp send_moqx_datagram(ctx, connection, config, sequence) do
    Transport.send_datagram(
      ctx,
      connection,
      DatagramPayload.encode(sequence, config.datagram_size, monotonic_us())
    )
  end

  defp datagram_send_failure(config, reason, sequence, offered, accepted) do
    %{
      "phase" => "send_datagram",
      "reason" => reason_name(reason),
      "datagram_sequence" => sequence,
      "datagrams_offered" => offered,
      "datagrams_accepted" => accepted,
      "datagram_size_bytes" => config.datagram_size,
      "target_datagrams_per_second" => target_datagram_rate(config),
      "target_duration_seconds" => target_duration_seconds(config),
      "offered_load_bps" => offered_load_bps(config),
      "topology" => config.topology
    }
  end

  defp initial_moqx_datagram_receive_state do
    %{
      received: MapSet.new(),
      latencies: [],
      first_byte_latency_ms: nil,
      process: %{},
      datagram_receive_events: 0,
      duplicate_datagrams: 0,
      invalid_datagrams: 0,
      ignored_events: 0,
      unknown_events: 0,
      receive_errors: 0,
      drain_events: 0
    }
    |> sample_process_diagnostics()
  end

  defp receive_moqx_datagrams_until(
         ctx,
         connection,
         receive_state,
         started_at,
         target_us
       ) do
    remaining_ms = max(ceil((target_us - monotonic_us()) / 1000), 0)

    case Transport.receive_event(ctx, remaining_ms) do
      {:ok, {:datagram, ^connection, payload, _metadata}, ctx} ->
        receive_state = record_moqx_datagram(payload, receive_state, started_at)

        receive_moqx_datagrams_until(
          ctx,
          connection,
          receive_state,
          started_at,
          target_us
        )

      {:ok, _event, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:ignored_events, &(&1 + 1))
          |> sample_process_diagnostics()

        receive_moqx_datagrams_until(
          ctx,
          connection,
          receive_state,
          started_at,
          target_us
        )

      {:unknown, _message, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:unknown_events, &(&1 + 1))
          |> sample_process_diagnostics()

        receive_moqx_datagrams_until(
          ctx,
          connection,
          receive_state,
          started_at,
          target_us
        )

      {:error, _reason, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:receive_errors, &(&1 + 1))
          |> sample_process_diagnostics()

        {receive_state, ctx}

      {:timeout, ctx} ->
        {sample_process_diagnostics(receive_state), ctx}
    end
  end

  defp drain_available_moqx_datagrams(
         ctx,
         connection,
         receive_state,
         started_at
       ) do
    case Transport.receive_event(ctx, 0) do
      {:ok, {:datagram, ^connection, payload, _metadata}, ctx} ->
        receive_state =
          payload
          |> record_moqx_datagram(receive_state, started_at)
          |> Map.update!(:drain_events, &(&1 + 1))
          |> sample_process_diagnostics()

        drain_available_moqx_datagrams(
          ctx,
          connection,
          receive_state,
          started_at
        )

      {:ok, _event, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:ignored_events, &(&1 + 1))
          |> Map.update!(:drain_events, &(&1 + 1))
          |> sample_process_diagnostics()

        drain_available_moqx_datagrams(
          ctx,
          connection,
          receive_state,
          started_at
        )

      {:unknown, _message, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:unknown_events, &(&1 + 1))
          |> Map.update!(:drain_events, &(&1 + 1))
          |> sample_process_diagnostics()

        drain_available_moqx_datagrams(
          ctx,
          connection,
          receive_state,
          started_at
        )

      {:error, _reason, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:receive_errors, &(&1 + 1))
          |> Map.update!(:drain_events, &(&1 + 1))
          |> sample_process_diagnostics()

        {receive_state, ctx}

      {:timeout, ctx} ->
        {sample_process_diagnostics(receive_state), ctx}
    end
  end

  defp receive_moqx_datagrams(
         ctx,
         connection,
         config,
         expected,
         receive_state,
         started_at
       ) do
    if MapSet.size(receive_state.received) >= expected or
         elapsed_ms(started_at) >= datagram_receive_timeout_ms(config) do
      {sample_process_diagnostics(receive_state), ctx}
    else
      receive_moqx_datagram(
        ctx,
        connection,
        config,
        expected,
        receive_state,
        started_at
      )
    end
  end

  defp receive_moqx_datagram(
         ctx,
         connection,
         config,
         expected,
         receive_state,
         started_at
       ) do
    remaining_ms = max(datagram_receive_timeout_ms(config) - trunc(elapsed_ms(started_at)), 0)

    case Transport.receive_event(ctx, remaining_ms) do
      {:ok, {:datagram, ^connection, payload, _metadata}, ctx} ->
        receive_state = record_moqx_datagram(payload, receive_state, started_at)

        receive_moqx_datagrams(
          ctx,
          connection,
          config,
          expected,
          receive_state,
          started_at
        )

      {:ok, _event, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:ignored_events, &(&1 + 1))
          |> sample_process_diagnostics()

        receive_moqx_datagrams(
          ctx,
          connection,
          config,
          expected,
          receive_state,
          started_at
        )

      {:unknown, _message, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:unknown_events, &(&1 + 1))
          |> sample_process_diagnostics()

        receive_moqx_datagrams(
          ctx,
          connection,
          config,
          expected,
          receive_state,
          started_at
        )

      {:error, _reason, ctx} ->
        receive_state =
          receive_state
          |> Map.update!(:receive_errors, &(&1 + 1))
          |> sample_process_diagnostics()

        receive_moqx_datagrams(
          ctx,
          connection,
          config,
          expected,
          receive_state,
          started_at
        )

      {:timeout, ctx} ->
        {sample_process_diagnostics(receive_state), ctx}
    end
  end

  defp record_moqx_datagram(
         payload,
         receive_state,
         started_at
       ) do
    receive_state = Map.update!(receive_state, :datagram_receive_events, &(&1 + 1))

    case DatagramPayload.decode(payload) do
      {:ok, sequence, sent_at} ->
        if MapSet.member?(receive_state.received, sequence) do
          Map.update!(receive_state, :duplicate_datagrams, &(&1 + 1))
        else
          latency = elapsed_ms(sent_at)

          %{
            receive_state
            | received: MapSet.put(receive_state.received, sequence),
              latencies: [latency | receive_state.latencies],
              first_byte_latency_ms: receive_state.first_byte_latency_ms || elapsed_ms(started_at)
          }
        end

      :error ->
        Map.update!(receive_state, :invalid_datagrams, &(&1 + 1))
    end
    |> sample_process_diagnostics()
  end

  defp empty_stream_result do
    %{
      bytes_sent: 0,
      bytes_received: 0,
      first_byte_latency_ms: nil,
      stream_latencies_ms: [],
      stream_diagnostics: [],
      failure: nil
    }
  end

  defp stream_direction(%{stream_direction: "bidirectional"}), do: :bidirectional
  defp stream_direction(%{stream_direction: "unidirectional"}), do: :unidirectional

  defp open_pressure_streams(ctx, connection, config) do
    Enum.reduce(1..config.stream_count, {[], ctx}, fn index, {streams, ctx} ->
      started_at = monotonic_us()

      {:ok, stream, ctx} =
        Transport.open_stream(ctx, connection, open_stream_opts(config))

      stream_state = %{
        index: index,
        stream: stream,
        started_at: started_at,
        bytes_sent: 0,
        payloads_accepted: 0
      }

      record_stream_phase(config, stream_state, "opened")

      {[stream_state | streams], ctx}
    end)
    |> then(fn {streams, ctx} -> {Enum.reverse(streams), ctx} end)
  end

  defp open_stream_opts(%{stream_direction: "bidirectional"} = config) do
    [direction: stream_direction(config), active: true]
  end

  defp open_stream_opts(config), do: [direction: stream_direction(config)]

  defp schedule_pressure_payloads(ctx, streams, payload, config) do
    Enum.reduce(1..config.payload_count, {streams, ctx}, fn payload_index, {streams, ctx} ->
      schedule_payload_round(streams, ctx, payload, payload_index == config.payload_count)
    end)
  end

  defp schedule_payload_round(streams, ctx, payload, finish?) do
    Enum.map_reduce(streams, ctx, fn stream_state, ctx ->
      schedule_stream_payload(stream_state, ctx, payload, finish?)
    end)
  end

  defp schedule_stream_payload(stream_state, ctx, payload, finish?) do
    opts = if finish?, do: [finish: true], else: []
    {:ok, _send, ctx} = Transport.send_stream(ctx, stream_state.stream, payload, opts)

    stream_state = %{
      stream_state
      | bytes_sent: stream_state.bytes_sent + byte_size(payload),
        payloads_accepted: stream_state.payloads_accepted + 1
    }

    {stream_state, ctx}
  end

  defp collect_pressure_streams(
         ctx,
         streams,
         payload,
         %{stream_direction: "bidirectional"} = config,
         first_byte_origin
       ) do
    collect_active_echo_streams(ctx, streams, payload, config, first_byte_origin)
  end

  defp collect_pressure_streams(ctx, streams, payload, config, first_byte_origin) do
    Enum.reduce_while(streams, {empty_stream_result(), ctx}, fn stream_state, {result, ctx} ->
      {stream_result, ctx} =
        collect_pressure_stream(ctx, stream_state, payload, config, first_byte_origin)

      result = merge_stream_result(result, stream_result)

      if result.failure do
        {:halt, {result, ctx}}
      else
        {:cont, {result, ctx}}
      end
    end)
  end

  defp collect_active_echo_streams(ctx, streams, payload, config, first_byte_origin) do
    states =
      Map.new(streams, fn stream_state ->
        record_stream_phase(config, stream_state, "awaiting_echo", %{
          "bytes_expected" => expected_stream_bytes(config)
        })

        {stream_state.stream,
         %{
           stream_state: stream_state,
           bytes_received: 0,
           first_byte_latency_ms: nil,
           completed_at: nil,
           first_send_accepted_at: nil,
           last_send_accepted_at: nil,
           first_echo_received_at: nil,
           last_echo_received_at: nil,
           payloads_scheduled: 0,
           payloads_completed: 0,
           send_inflight: 0,
           send_completed: 0,
           send_cancelled: 0,
           send_call_durations_us: [],
           peer_finished?: false,
           failure: nil
         }}
      end)

    diagnostics = initial_stream_pressure_runtime(first_byte_origin)
    {states, ctx} = prime_active_echo_sends(ctx, states, payload, config)
    diagnostics = sample_stream_pressure_runtime(diagnostics, config)
    deadline_us = monotonic_us() + client_timeout_ms(config) * 1000

    collect_active_echo_events(
      ctx,
      states,
      diagnostics,
      payload,
      config,
      first_byte_origin,
      deadline_us
    )
  end

  defp initial_stream_pressure_runtime(started_at) do
    %{
      process: %{"started_at_us" => started_at},
      events_drained: 0,
      stream_data_events: 0,
      send_completed_events: 0,
      send_cancelled_events: 0,
      peer_finished_events: 0,
      stream_closed_events: 0,
      ignored_events: 0,
      unknown_events: 0,
      receive_errors: 0,
      timeouts: 0,
      timeout_phase: nil,
      receive_event_call_durations_us: [],
      receive_event_blocking_call_durations_us: [],
      receive_event_drain_call_durations_us: []
    }
  end

  defp sample_stream_pressure_runtime(diagnostics, _config), do: diagnostics

  defp collect_active_echo_events(
         ctx,
         states,
         diagnostics,
         payload,
         config,
         first_byte_origin,
         deadline_us
       ) do
    cond do
      all_streams_complete?(states) ->
        active_echo_result(ctx, states, config, nil, diagnostics)

      failure = first_stream_failure(states) ->
        active_echo_result(ctx, states, config, failure, diagnostics)

      monotonic_us() >= deadline_us ->
        failure = timeout_stream_failure(states, config)
        diagnostics = timeout_stream_pressure_runtime(diagnostics, config, "echo_receive")

        active_echo_result(
          ctx,
          mark_timeout_failure(states, failure),
          config,
          failure,
          diagnostics
        )

      true ->
        timeout_ms = max(div(deadline_us - monotonic_us(), 1000), 0)

        receive_result = Transport.receive_event(ctx, timeout_ms)

        case receive_result do
          {:ok, event, ctx} ->
            {ctx, states, diagnostics} =
              handle_active_echo_received_event(
                ctx,
                states,
                diagnostics,
                event,
                payload,
                config,
                first_byte_origin
              )

            {ctx, states, diagnostics} =
              drain_ready_active_echo_events(
                ctx,
                states,
                diagnostics,
                payload,
                config,
                first_byte_origin
              )

            diagnostics = sample_stream_pressure_runtime(diagnostics, config)

            collect_active_echo_events(
              ctx,
              states,
              diagnostics,
              payload,
              config,
              first_byte_origin,
              deadline_us
            )

          {:unknown, _message, ctx} ->
            diagnostics =
              diagnostics
              |> Map.update!(:unknown_events, &(&1 + 1))
              |> sample_stream_pressure_runtime(config)

            collect_active_echo_events(
              ctx,
              states,
              diagnostics,
              payload,
              config,
              first_byte_origin,
              deadline_us
            )

          {:error, reason, ctx} ->
            failure = receive_event_failure(states, config, reason)

            diagnostics =
              diagnostics
              |> Map.update!(:receive_errors, &(&1 + 1))
              |> sample_stream_pressure_runtime(config)

            active_echo_result(
              ctx,
              mark_timeout_failure(states, failure),
              config,
              failure,
              diagnostics
            )

          {:timeout, ctx} ->
            failure = timeout_stream_failure(states, config)

            diagnostics = timeout_stream_pressure_runtime(diagnostics, config, "echo_receive")

            active_echo_result(
              ctx,
              mark_timeout_failure(states, failure),
              config,
              failure,
              diagnostics
            )
        end
    end
  end

  defp handle_active_echo_received_event(
         ctx,
         states,
         diagnostics,
         event,
         payload,
         config,
         first_byte_origin
       ) do
    {states, ctx} =
      handle_active_echo_event(ctx, states, event, payload, config, first_byte_origin)

    {ctx, states, diagnostics}
  end

  defp drain_ready_active_echo_events(
         ctx,
         states,
         diagnostics,
         payload,
         config,
         first_byte_origin
       ) do
    drain_ready_active_echo_events(
      ctx,
      states,
      diagnostics,
      payload,
      config,
      first_byte_origin,
      config.stream_event_batch_size - 1
    )
  end

  defp drain_ready_active_echo_events(
         ctx,
         states,
         diagnostics,
         _payload,
         _config,
         _first_byte_origin,
         remaining
       )
       when remaining <= 0 do
    {ctx, states, diagnostics}
  end

  defp drain_ready_active_echo_events(
         ctx,
         states,
         diagnostics,
         payload,
         config,
         first_byte_origin,
         remaining
       ) do
    if all_streams_complete?(states) or first_stream_failure(states) do
      {ctx, states, diagnostics}
    else
      drain_ready_active_echo_event(
        ctx,
        states,
        diagnostics,
        payload,
        config,
        first_byte_origin,
        remaining
      )
    end
  end

  defp drain_ready_active_echo_event(
         ctx,
         states,
         diagnostics,
         payload,
         config,
         first_byte_origin,
         remaining
       ) do
    receive_result = Transport.receive_event(ctx, 0)

    case receive_result do
      {:ok, event, ctx} ->
        {ctx, states, diagnostics} =
          handle_active_echo_received_event(
            ctx,
            states,
            diagnostics,
            event,
            payload,
            config,
            first_byte_origin
          )

        drain_ready_active_echo_events(
          ctx,
          states,
          diagnostics,
          payload,
          config,
          first_byte_origin,
          remaining - 1
        )

      {:unknown, _message, ctx} ->
        diagnostics = Map.update!(diagnostics, :unknown_events, &(&1 + 1))

        drain_ready_active_echo_events(
          ctx,
          states,
          diagnostics,
          payload,
          config,
          first_byte_origin,
          remaining - 1
        )

      {:timeout, ctx} ->
        {ctx, states, diagnostics}

      {:error, reason, ctx} ->
        failure = receive_event_failure(states, config, reason)
        diagnostics = Map.update!(diagnostics, :receive_errors, &(&1 + 1))
        {ctx, mark_timeout_failure(states, failure), diagnostics}
    end
  end

  defp timeout_stream_pressure_runtime(diagnostics, config, phase) do
    diagnostics
    |> Map.update!(:timeouts, &(&1 + 1))
    |> Map.put(:timeout_phase, phase)
    |> sample_stream_pressure_runtime(config)
  end

  defp prime_active_echo_sends(ctx, states, payload, config) do
    Enum.reduce(states, {%{}, ctx}, fn {stream, state}, {states, ctx} ->
      {state, ctx} = schedule_active_stream_sends(ctx, state, payload, config)
      {Map.put(states, stream, state), ctx}
    end)
  end

  defp schedule_active_stream_sends(ctx, state, payload, config) do
    cond do
      state.failure ->
        {state, ctx}

      state.payloads_scheduled >= config.payload_count ->
        {state, ctx}

      state.send_inflight >= config.stream_send_window ->
        {state, ctx}

      true ->
        payload_index = state.payloads_scheduled + 1
        finish? = payload_index == config.payload_count
        opts = if finish?, do: [finish: true], else: []
        send_started_at = monotonic_us()
        send_result = Transport.send_stream(ctx, state.stream_state.stream, payload, opts)
        accepted_at = monotonic_us()
        send_call_duration_us = accepted_at - send_started_at

        case send_result do
          {:ok, _send, ctx} ->
            stream_state = %{
              state.stream_state
              | bytes_sent: state.stream_state.bytes_sent + byte_size(payload),
                payloads_accepted: state.stream_state.payloads_accepted + 1
            }

            state = %{
              state
              | stream_state: stream_state,
                payloads_scheduled: payload_index,
                send_inflight: state.send_inflight + 1,
                first_send_accepted_at: state.first_send_accepted_at || accepted_at,
                last_send_accepted_at: accepted_at,
                send_call_durations_us: [
                  send_call_duration_us | state.send_call_durations_us
                ]
            }

            record_stream_phase(config, stream_state, "send_window_open", %{
              "bytes_expected" => expected_stream_bytes(config),
              "payloads_scheduled" => state.payloads_scheduled,
              "send_inflight" => state.send_inflight,
              "send_window" => config.stream_send_window
            })

            schedule_active_stream_sends(ctx, state, payload, config)

          {:error, reason, ctx} ->
            state = %{
              state
              | send_call_durations_us: [
                  send_call_duration_us | state.send_call_durations_us
                ]
            }

            {fail_active_stream(state, config, reason_name(reason)), ctx}
        end
    end
  end

  defp handle_active_echo_event(
         ctx,
         states,
         {:stream_data, stream, data, _metadata},
         payload,
         config,
         first_byte_origin
       ) do
    states =
      Map.update!(states, stream, fn state ->
        handle_active_stream_data(state, data, payload, config, first_byte_origin)
      end)

    {states, ctx}
  end

  defp handle_active_echo_event(
         ctx,
         states,
         {:stream_event, stream, :send_completed, _metadata},
         payload,
         config,
         _first_byte_origin
       ) do
    state =
      states
      |> Map.fetch!(stream)
      |> Map.update!(:send_completed, &(&1 + 1))
      |> Map.update!(:payloads_completed, &(&1 + 1))
      |> Map.update!(:send_inflight, &max(&1 - 1, 0))

    {state, ctx} = schedule_active_stream_sends(ctx, state, payload, config)
    {Map.put(states, stream, state), ctx}
  end

  defp handle_active_echo_event(
         ctx,
         states,
         {:stream_event, stream, :send_cancelled, _metadata},
         _payload,
         config,
         _first_byte_origin
       ) do
    states =
      Map.update!(states, stream, fn state ->
        state = update_in(state, [:send_cancelled], &((&1 || 0) + 1))
        fail_active_stream(state, config, "send_cancelled")
      end)

    {states, ctx}
  end

  defp handle_active_echo_event(
         ctx,
         states,
         {:stream_event, stream, :peer_finished_sending, _metadata},
         _payload,
         config,
         _first_byte_origin
       ) do
    states =
      Map.update!(states, stream, fn state ->
        state = %{state | peer_finished?: true}

        if state.bytes_received >= expected_stream_bytes(config) do
          state
        else
          fail_active_stream(state, config, "peer_send_shutdown")
        end
      end)

    {states, ctx}
  end

  defp handle_active_echo_event(
         ctx,
         states,
         {:stream_event, stream, :closed, _metadata},
         _payload,
         config,
         _first_byte_origin
       ) do
    states =
      Map.update!(states, stream, fn state ->
        if state.bytes_received >= expected_stream_bytes(config) do
          state
        else
          fail_active_stream(state, config, "closed")
        end
      end)

    {states, ctx}
  end

  defp handle_active_echo_event(ctx, states, _event, _payload, _config, _first_byte_origin),
    do: {states, ctx}

  defp handle_active_stream_data(state, data, payload, config, first_byte_origin) do
    received = state.bytes_received

    if matches_payload?(data, payload, received) do
      record_active_stream_data(state, byte_size(data), config, first_byte_origin)
    else
      fail_active_stream(state, config, "echo_payload_mismatch")
    end
  end

  defp record_active_stream_data(state, byte_count, config, first_byte_origin) do
    received_at = monotonic_us()
    received = state.bytes_received + byte_count
    first_byte_latency_ms = state.first_byte_latency_ms || elapsed_ms(first_byte_origin)
    completed_at = if received >= expected_stream_bytes(config), do: received_at
    phase = if completed_at, do: "echo_complete", else: "receiving_echo"

    state = %{
      state
      | bytes_received: received,
        first_byte_latency_ms: first_byte_latency_ms,
        completed_at: completed_at,
        first_echo_received_at: state.first_echo_received_at || received_at,
        last_echo_received_at: received_at
    }

    record_stream_phase(config, state.stream_state, phase, %{
      "bytes_expected" => expected_stream_bytes(config),
      "bytes_received" => received,
      "send_completed" => state.send_completed,
      "send_cancelled" => state.send_cancelled
    })

    state
  end

  defp fail_active_stream(state, config, reason) do
    failure = active_stream_failure(state, config, reason)

    record_stream_phase(config, state.stream_state, "echo_failed", %{
      "bytes_expected" => expected_stream_bytes(config),
      "bytes_received" => state.bytes_received,
      "error" => reason,
      "incomplete_bytes" => max(expected_stream_bytes(config) - state.bytes_received, 0),
      "send_completed" => state.send_completed,
      "send_cancelled" => state.send_cancelled
    })

    %{state | failure: failure}
  end

  defp active_stream_failure(state, config, reason) do
    %{
      "phase" => "echo_failed",
      "reason" => reason,
      "stream_index" => state.stream_state.index,
      "stream_id" => stream_id(state.stream_state.stream),
      "bytes_expected" => expected_stream_bytes(config),
      "bytes_received" => state.bytes_received,
      "incomplete_bytes" => max(expected_stream_bytes(config) - state.bytes_received, 0),
      "send_completed" => state.send_completed,
      "send_cancelled" => state.send_cancelled
    }
  end

  defp active_echo_result(ctx, states, config, failure, runtime_diagnostics) do
    diagnostics =
      states
      |> Map.values()
      |> Enum.map(&active_stream_diagnostic(&1, config))

    result = %{
      bytes_sent: states |> Map.values() |> Enum.map(& &1.stream_state.bytes_sent) |> Enum.sum(),
      bytes_received: states |> Map.values() |> Enum.map(& &1.bytes_received) |> Enum.sum(),
      first_byte_latency_ms: first_observed_latency(states, :first_byte_latency_ms),
      stream_latencies_ms: active_stream_latencies(states),
      stream_diagnostics: diagnostics,
      send_stream_call_durations_us: active_send_call_durations_us(states),
      runtime_diagnostics: runtime_diagnostics,
      active_send_duration_ms: active_send_duration_ms(states),
      active_echo_receive_duration_ms: active_echo_receive_duration_ms(states),
      failure: failure
    }

    {result, ctx}
  end

  defp active_stream_diagnostic(state, config) do
    phase =
      cond do
        state.failure -> "echo_failed"
        state.bytes_received >= expected_stream_bytes(config) -> "echo_complete"
        true -> "receiving_echo"
      end

    stream_diagnostic(
      state.stream_state,
      expected_stream_bytes(config),
      state.bytes_received,
      phase,
      %{
        "send_completed" => state.send_completed,
        "send_cancelled" => state.send_cancelled,
        "payloads_scheduled" => state.payloads_scheduled,
        "payloads_completed" => state.payloads_completed,
        "send_inflight" => state.send_inflight,
        "send_completions_pending" => state.send_inflight,
        "send_stream_call_ms" => duration_summary_ms(state.send_call_durations_us),
        "active_send_duration_ms" =>
          duration_ms_between(state.first_send_accepted_at, state.last_send_accepted_at),
        "active_echo_receive_duration_ms" =>
          duration_ms_between(state.first_echo_received_at, state.last_echo_received_at),
        "peer_finished" => state.peer_finished?,
        "error" => state.failure && state.failure["reason"]
      }
    )
  end

  defp active_send_duration_ms(states) do
    states
    |> Map.values()
    |> duration_ms_between_values(:first_send_accepted_at, :last_send_accepted_at)
  end

  defp active_echo_receive_duration_ms(states) do
    states
    |> Map.values()
    |> duration_ms_between_values(:first_echo_received_at, :last_echo_received_at)
  end

  defp active_send_call_durations_us(states) do
    states
    |> Map.values()
    |> Enum.flat_map(& &1.send_call_durations_us)
  end

  defp duration_ms_between_values(values, first_key, last_key) do
    first =
      values
      |> Enum.map(&Map.get(&1, first_key))
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    last =
      values
      |> Enum.map(&Map.get(&1, last_key))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    duration_ms_between(first, last)
  end

  defp duration_ms_between(nil, _last), do: nil
  defp duration_ms_between(_first, nil), do: nil
  defp duration_ms_between(first, last), do: max(last - first, 0) / 1000

  defp active_stream_latencies(states) do
    states
    |> Map.values()
    |> Enum.map(fn state ->
      finished_at = state.completed_at || monotonic_us()
      (finished_at - state.stream_state.started_at) / 1000
    end)
  end

  defp first_observed_latency(states, key) do
    case states |> Map.values() |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> Enum.min(values)
    end
  end

  defp all_streams_complete?(states) do
    Enum.all?(states, fn {_stream, state} -> !is_nil(state.completed_at) end)
  end

  defp first_stream_failure(states) do
    states
    |> Map.values()
    |> Enum.map(& &1.failure)
    |> Enum.find(&is_map/1)
  end

  defp timeout_stream_failure(states, config) do
    state =
      states
      |> Map.values()
      |> Enum.reject(& &1.completed_at)
      |> Enum.min_by(& &1.stream_state.index, fn -> nil end)

    if state, do: active_stream_failure(state, config, "receive_timeout")
  end

  defp receive_event_failure(states, config, reason) do
    state =
      states
      |> Map.values()
      |> Enum.reject(& &1.completed_at)
      |> Enum.min_by(& &1.stream_state.index, fn -> nil end)

    if state, do: active_stream_failure(state, config, reason_name(reason))
  end

  defp mark_timeout_failure(states, nil), do: states

  defp mark_timeout_failure(states, failure) do
    {_stream, state} =
      Enum.find(states, fn {_stream, state} ->
        state.stream_state.index == failure["stream_index"]
      end)

    Map.put(states, state.stream_state.stream, %{state | failure: failure})
  end

  defp collect_pressure_stream(ctx, stream_state, payload, config, first_byte_origin) do
    {received, first_byte_latency_ms, ctx, diagnostic, failure} =
      if config.stream_direction == "bidirectional" do
        recv_echo_payload(
          config,
          ctx,
          stream_state,
          payload,
          config.payload_count,
          first_byte_origin
        )
      else
        diagnostic =
          stream_diagnostic(stream_state, 0, 0, "send_only_complete", %{
            "latency_ms" => elapsed_ms(stream_state.started_at)
          })

        record_stream_phase(config, stream_state, "send_only_complete", diagnostic)
        {0, nil, ctx, diagnostic, nil}
      end

    {%{
       bytes_sent: stream_state.bytes_sent,
       bytes_received: received,
       first_byte_latency_ms: first_byte_latency_ms,
       stream_latencies_ms: [elapsed_ms(stream_state.started_at)],
       stream_diagnostics: [diagnostic],
       failure: failure
     }, ctx}
  end

  defp recv_echo_payload(config, ctx, stream_state, payload, count, first_byte_origin) do
    expected_bytes = byte_size(payload) * count

    record_stream_phase(config, stream_state, "receiving_echo", %{
      "bytes_expected" => expected_bytes
    })

    recv_echo_payload(
      config,
      ctx,
      stream_state,
      payload,
      expected_bytes,
      0,
      nil,
      first_byte_origin
    )
  end

  defp recv_echo_payload(
         config,
         ctx,
         stream_state,
         _payload,
         expected_bytes,
         expected_bytes,
         first_byte_latency_ms,
         _first_byte_origin
       ) do
    diagnostic = stream_diagnostic(stream_state, expected_bytes, expected_bytes, "echo_complete")
    record_stream_phase(config, stream_state, "echo_complete", diagnostic)
    {expected_bytes, first_byte_latency_ms, ctx, diagnostic, nil}
  end

  defp recv_echo_payload(
         config,
         ctx,
         stream_state,
         payload,
         expected_bytes,
         received,
         first_byte_latency_ms,
         first_byte_origin
       ) do
    remaining = expected_bytes - received
    read_size = min(remaining, byte_size(payload))

    case Transport.recv_stream(ctx, stream_state.stream, read_size) do
      {:ok, data, ctx} ->
        if matches_payload?(data, payload, received) do
          first_byte_latency_ms = first_byte_latency_ms || elapsed_ms(first_byte_origin)

          recv_echo_payload(
            config,
            ctx,
            stream_state,
            payload,
            expected_bytes,
            received + byte_size(data),
            first_byte_latency_ms,
            first_byte_origin
          )
        else
          stream_failure(
            config,
            ctx,
            stream_state,
            expected_bytes,
            received + byte_size(data),
            "echo_payload_mismatch"
          )
        end

      {:error, reason, ctx} ->
        stream_failure(config, ctx, stream_state, expected_bytes, received, reason)
    end
  end

  defp stream_failure(config, ctx, stream_state, expected_bytes, received, reason) do
    reason = reason_name(reason)

    diagnostic =
      stream_diagnostic(stream_state, expected_bytes, received, "echo_failed", %{
        "error" => reason,
        "incomplete_bytes" => max(expected_bytes - received, 0)
      })

    failure = %{
      "phase" => "echo_failed",
      "reason" => reason,
      "stream_index" => stream_state.index,
      "stream_id" => stream_id(stream_state.stream),
      "bytes_expected" => expected_bytes,
      "bytes_received" => received,
      "incomplete_bytes" => max(expected_bytes - received, 0)
    }

    record_stream_phase(config, stream_state, "echo_failed", diagnostic)
    {received, nil, ctx, diagnostic, failure}
  end

  defp stream_pressure_diagnostics(config, streams, result, application_duration_ms) do
    streamed =
      Map.new(result.stream_diagnostics, fn diagnostic -> {diagnostic["index"], diagnostic} end)

    stream_diagnostics =
      Enum.map(streams, fn stream_state ->
        Map.get_lazy(streamed, stream_state.index, fn ->
          stream_diagnostic(
            stream_state,
            expected_stream_bytes(config),
            0,
            "scheduled_not_collected"
          )
        end)
      end)

    runtime = Map.get(result, :runtime_diagnostics, %{})

    summary =
      %{
        "streams_opened" => length(streams),
        "streams_completed" => count_phase(stream_diagnostics, "echo_complete"),
        "streams_failed" => count_phase(stream_diagnostics, "echo_failed"),
        "stream_send_window" => config.stream_send_window,
        "stream_event_batch_size" => config.stream_event_batch_size,
        "stream_diagnostics_sampling" => config.stream_diagnostics_sampling,
        "payloads_accepted" =>
          stream_diagnostics |> Enum.map(&(&1["payloads_accepted"] || 0)) |> Enum.sum(),
        "payloads_completed" =>
          stream_diagnostics |> Enum.map(&(&1["payloads_completed"] || 0)) |> Enum.sum(),
        "send_completions" =>
          stream_diagnostics |> Enum.map(&(&1["send_completed"] || 0)) |> Enum.sum(),
        "send_cancellations" =>
          stream_diagnostics |> Enum.map(&(&1["send_cancelled"] || 0)) |> Enum.sum(),
        "send_completions_pending" =>
          stream_diagnostics
          |> Enum.map(&(&1["send_completions_pending"] || 0))
          |> Enum.sum(),
        "bytes_sent" => result.bytes_sent,
        "stream_send_accepted" => Map.get(result, :stream_send_accepted),
        "stream_send_bytes_accepted" => Map.get(result, :stream_send_bytes_accepted),
        "stream_send_errors" => Map.get(result, :stream_send_errors),
        "bytes_expected" => expected_stream_bytes(config) * length(streams),
        "bytes_received" => result.bytes_received,
        "stream_data_bytes_received" => runtime[:stream_data_bytes_received],
        "send_stream_call_ms" => duration_summary_ms(result.send_stream_call_durations_us),
        "active_send_duration_ms" => Map.get(result, :active_send_duration_ms),
        "active_echo_receive_duration_ms" => Map.get(result, :active_echo_receive_duration_ms),
        "receive_event_call_ms" =>
          duration_summary_ms(runtime[:receive_event_call_durations_us] || []),
        "receive_event_blocking_call_ms" =>
          duration_summary_ms(runtime[:receive_event_blocking_call_durations_us] || []),
        "receive_event_drain_call_ms" =>
          duration_summary_ms(runtime[:receive_event_drain_call_durations_us] || []),
        "events_drained" => runtime[:events_drained],
        "stream_data_events" => runtime[:stream_data_events],
        "send_completed_events" => runtime[:send_completed_events],
        "send_cancelled_events" => runtime[:send_cancelled_events],
        "peer_finished_events" => runtime[:peer_finished_events],
        "stream_closed_events" => runtime[:stream_closed_events],
        "ignored_events" => runtime[:ignored_events],
        "unknown_events" => runtime[:unknown_events],
        "receive_errors" => runtime[:receive_errors],
        "timeouts" => runtime[:timeouts],
        "timeout_phase" => runtime[:timeout_phase],
        "application_duration_ms" => application_duration_ms,
        "failure" => result.failure
      }
      |> compact()

    %{
      "version" => "stream-pressure-diagnostics-v1",
      "summary" => summary,
      "streams" => stream_diagnostics,
      "process" => process_diagnostics(Map.get(runtime, :process, %{}))
    }
  end

  defp count_phase(stream_diagnostics, phase) do
    Enum.count(stream_diagnostics, fn diagnostic -> diagnostic["phase"] == phase end)
  end

  defp expected_stream_bytes(config), do: config.payload_size * config.payload_count

  defp stream_diagnostic(stream_state, expected_bytes, received, phase, extra \\ %{}) do
    diagnostic =
      %{
        "index" => stream_state.index,
        "stream_id" => stream_id(stream_state.stream),
        "direction" => stream_direction_name(stream_state.stream),
        "phase" => phase,
        "payloads_accepted" => stream_state.payloads_accepted,
        "bytes_sent" => stream_state.bytes_sent,
        "bytes_expected" => expected_bytes,
        "bytes_received" => received,
        "send_completions_pending" => stream_state.payloads_accepted
      }
      |> Map.merge(extra)
      |> compact()

    Map.put(diagnostic, "completion_status", stream_completion_status(diagnostic))
  end

  defp stream_completion_status(%{"error" => error}) when not is_nil(error), do: "failed"

  defp stream_completion_status(%{"send_cancelled" => cancelled})
       when is_integer(cancelled) and cancelled > 0,
       do: "cancelled"

  defp stream_completion_status(%{"send_completions_pending" => pending})
       when is_integer(pending) and pending > 0,
       do: "pending"

  defp stream_completion_status(%{"phase" => phase})
       when phase in ["echo_complete", "send_only_complete"],
       do: "completed"

  defp stream_completion_status(_diagnostic), do: "in_progress"

  defp stream_id(%{info: %{stream_id: stream_id}}), do: stream_id

  defp stream_direction_name(%{info: %{direction: direction}}) when is_atom(direction),
    do: Atom.to_string(direction)

  defp stream_direction_name(_stream), do: nil

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(reason), do: inspect(reason)

  defp matches_payload?(chunk, payload, offset) do
    payload
    |> expected_payload_chunk(offset, byte_size(chunk))
    |> then(&(&1 == chunk))
  end

  defp expected_payload_chunk(_payload, _offset, 0), do: <<>>

  defp expected_payload_chunk(payload, offset, size) do
    payload_size = byte_size(payload)
    start = rem(offset, payload_size)
    first_size = min(size, payload_size - start)
    remaining = size - first_size

    [
      :binary.part(payload, start, first_size),
      repeated_payload(payload, payload_size, remaining),
      payload_tail(payload, payload_size, remaining)
    ]
    |> IO.iodata_to_binary()
  end

  defp repeated_payload(_payload, _payload_size, 0), do: []

  defp repeated_payload(payload, payload_size, remaining) do
    repeat_count = div(remaining, payload_size)
    :binary.copy(payload, repeat_count)
  end

  defp payload_tail(_payload, _payload_size, 0), do: []

  defp payload_tail(payload, payload_size, remaining) do
    tail_size = rem(remaining, payload_size)
    :binary.part(payload, 0, tail_size)
  end

  defp merge_stream_result(left, right) do
    %{
      bytes_sent: left.bytes_sent + right.bytes_sent,
      bytes_received: left.bytes_received + right.bytes_received,
      first_byte_latency_ms: left.first_byte_latency_ms || right.first_byte_latency_ms,
      stream_latencies_ms: left.stream_latencies_ms ++ right.stream_latencies_ms,
      stream_diagnostics: left.stream_diagnostics ++ right.stream_diagnostics,
      failure: left.failure || right.failure
    }
  end

  defp maybe_append_servername(args, nil), do: args
  defp maybe_append_servername(args, servername), do: args ++ ["--servername", servername]

  defp run_command(command, args, timeout_ms) do
    executable = resolve_executable!(command)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    timer = Process.send_after(self(), {:quicprobe_timeout, port}, timeout_ms)

    try do
      collect_port(port, [])
    after
      Process.cancel_timer(timer)
      flush_timeout(port)
    end
  end

  defp resolve_executable!(command) do
    cond do
      Path.type(command) == :absolute && File.exists?(command) ->
        command

      executable = System.find_executable(command) ->
        executable

      true ->
        raise "quicprobe command not found: #{command}"
    end
  end

  defp collect_port(port, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, [data | chunks])

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(Enum.reverse(chunks)), status, false}

      {:quicprobe_timeout, ^port} ->
        terminate_port(port)
        {IO.iodata_to_binary(Enum.reverse(chunks)), @timeout_exit_status, true}
    end
  end

  defp terminate_port(port) do
    os_pid = port_os_pid(port)
    signal_pid(os_pid, "TERM")

    unless wait_for_port_exit(port, 250) do
      signal_pid(os_pid, "KILL")
    end

    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp signal_pid(nil, _signal), do: :ok

  defp signal_pid(pid, signal) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    ErlangError -> :ok
  end

  defp wait_for_port_exit(port, timeout_ms) do
    receive do
      {^port, {:data, _data}} -> wait_for_port_exit(port, timeout_ms)
      {^port, {:exit_status, _status}} -> true
    after
      timeout_ms -> false
    end
  end

  defp flush_timeout(port) do
    receive do
      {:quicprobe_timeout, ^port} -> :ok
    after
      0 -> :ok
    end
  end

  defp build_record(ctx) do
    %{
      "schema_version" => @schema_version,
      "record_type" => "step_summary",
      "run" => run_metadata(ctx),
      "path" => path_metadata(ctx.config),
      "software" => software_metadata(ctx),
      "profile" => profile_metadata(ctx),
      "workload" => workload_metadata(ctx),
      "methodology" => methodology_metadata(ctx),
      "metrics" => metrics(ctx),
      "limits" => limits(ctx),
      "errors" => errors(ctx),
      "diagnostics" => diagnostics(ctx)
    }
  end

  defp run_metadata(ctx) do
    %{
      "run_id" => ctx.config.run_id,
      "started_at" => ctx.run_started_at,
      "finished_at" => ctx.step_finished_at,
      "git_sha" => BuildInfo.git_sha(),
      "script" => ctx.config.script,
      "script_version" => @script_version,
      "command" => ctx.config.command,
      "notes" => ctx.config.notes,
      "step_started_at" => ctx.step_started_at,
      "step_command" => Enum.join(ctx.step_args, " ")
    }
  end

  defp path_metadata(config) do
    base =
      case config.path_json do
        nil -> default_path(config)
        path -> PathMetadata.load_json!(path)
      end

    deep_merge(base, compact(config.path_overrides))
  end

  defp default_path(config) do
    loopback? = loopback?(config.server)
    evidence_tier = if loopback?, do: "loopback_calibration", else: "edge_to_server"

    %{
      "evidence_tier" => evidence_tier,
      "path_id" => "#{evidence_tier}-#{config.topology}-#{config.server}-#{config.port}",
      "client" => client_path_metadata(loopback?),
      "server" => server_path_metadata(config.server, loopback?)
    }
  end

  defp client_path_metadata(loopback?) do
    %{
      "host_id" => hostname(),
      "provider" => local_only(loopback?, "local"),
      "region" => nil,
      "instance_class" => nil,
      "os" => os_description(),
      "kernel" => kernel(),
      "cpu_model" => cpu_model(),
      "memory_bytes" => memory_bytes(),
      "nic_or_network_class" => local_only(loopback?, "loopback")
    }
  end

  defp server_path_metadata(server, loopback?) do
    %{
      "host_id" => server,
      "provider" => local_only(loopback?, "local"),
      "region" => nil,
      "instance_class" => nil,
      "os" => local_only(loopback?, os_description()),
      "kernel" => local_only(loopback?, kernel()),
      "cpu_model" => local_only(loopback?, cpu_model()),
      "memory_bytes" => local_only(loopback?, memory_bytes()),
      "nic_or_network_class" => local_only(loopback?, "loopback")
    }
  end

  defp local_only(true, value), do: value
  defp local_only(false, _value), do: nil

  defp software_metadata(ctx) do
    measurement = measurement(ctx)

    %{
      "elixir_version" => System.version(),
      "otp_version" => System.otp_release(),
      "moqx_version" => moqx_version(),
      "quicer_version" => quicer_version(ctx.config),
      "msquic_version" => nil,
      "reference_implementation" => measurement["reference_implementation"] || "quicprobe",
      "reference_version" => measurement["reference_version"]
    }
  end

  defp quicer_version(%{topology: @moqx_client_topology}), do: app_version(:quicer)
  defp quicer_version(_config), do: nil

  defp profile_metadata(ctx) do
    measurement = measurement(ctx)

    %{
      "name" => "reference_quic",
      "alpn" => measurement["alpn"] || ctx.config.alpn,
      "datagrams" => ctx.config.workload == @datagram_pressure_workload,
      "congestion_control" => nil,
      "pacing" => datagram_pacing(ctx.config),
      "settings" => %{
        "topology" => ctx.config.topology,
        "workload" => measurement["workload"] || ctx.config.workload,
        "datagram_mode" => measurement["datagram_mode"] || profile_datagram_mode(ctx.config),
        "delivery_threshold" => ctx.config.delivery_threshold,
        "offered_rate_tolerance" => ctx.config.offered_rate_tolerance,
        "reference_tool" => "quicprobe",
        "measurement_schema" => measurement["schema_version"],
        "client_implementation" => measurement["client_implementation"] || "quicprobe",
        "server_implementation" => server_implementation(ctx.config),
        "stream_scheduling" => stream_scheduling(ctx.config, measurement),
        "stream_send_window" => stream_send_window(ctx.config, measurement),
        "stream_event_batch_size" => stream_event_batch_size(ctx.config, measurement),
        "stream_diagnostics_sampling" => stream_diagnostics_sampling(ctx.config, measurement)
      }
    }
  end

  defp stream_send_window(%{topology: @moqx_client_topology} = config, measurement),
    do: measurement["stream_send_window"] || config.stream_send_window

  defp stream_send_window(_config, _measurement), do: nil

  defp stream_event_batch_size(%{topology: @moqx_client_topology} = config, measurement),
    do: measurement["stream_event_batch_size"] || config.stream_event_batch_size

  defp stream_event_batch_size(_config, _measurement), do: nil

  defp stream_diagnostics_sampling(%{topology: @moqx_client_topology} = config, measurement),
    do: measurement["stream_diagnostics_sampling"] || config.stream_diagnostics_sampling

  defp stream_diagnostics_sampling(_config, _measurement), do: nil

  defp stream_scheduling(%{workload: @datagram_pressure_workload}, _measurement), do: nil

  defp stream_scheduling(%{workload: @mixed_moqt_shaped_workload}, measurement) do
    measurement["stream_scheduling"] || "mixed_control_bidi_object_uni"
  end

  defp stream_scheduling(config, measurement) do
    measurement["stream_scheduling"] || default_stream_scheduling(config)
  end

  defp default_stream_scheduling(%{topology: @reference_client_topology}), do: "concurrent"

  defp default_stream_scheduling(%{topology: @reference_client_moqx_listener_topology}),
    do: "concurrent"

  defp default_stream_scheduling(%{topology: @moqx_client_topology}), do: "concurrent"

  defp server_implementation(%{topology: @reference_client_moqx_listener_topology}), do: "moqx"
  defp server_implementation(_config), do: "quicprobe"

  defp workload_metadata(ctx) do
    measurement = measurement(ctx)
    duration_seconds = seconds(measurement["application_duration_ms"])
    stream_count = workload_stream_count(ctx.config, measurement)
    payload_count = workload_payload_count(ctx.config, measurement)

    %{
      "family" => workload_family(ctx.config),
      "direction" => "client_to_server",
      "stream_direction" => workload_stream_direction(ctx.config, measurement),
      "stream_count" => stream_count,
      "payload_size_bytes" =>
        measurement["payload_size_bytes"] || workload_payload_size(ctx.config),
      "payloads_per_second" => payloads_per_second(stream_count, payload_count, duration_seconds),
      "offered_load_bps" =>
        number(measurement["offered_load_bps"]) || offered_load_bps(ctx.config),
      "datagram_size_bytes" => workload_datagram_size(ctx.config, measurement),
      "datagrams_per_second" => workload_datagram_rate(ctx.config, measurement),
      "control_trickle_bps" =>
        number(measurement["control_trickle_bps"]) || control_trickle_bps(ctx.config),
      "topology" => ctx.config.topology,
      "tool" => workload_tool(ctx.config),
      "server" => ctx.config.server,
      "port" => ctx.config.port
    }
  end

  defp workload_tool(%{topology: @moqx_client_topology}), do: "moqx"
  defp workload_tool(_config), do: "quicprobe"

  defp workload_family(%{workload: @mixed_moqt_shaped_workload}), do: @mixed_moqt_shaped_workload
  defp workload_family(_config), do: "reference_comparison"

  defp workload_stream_count(%{workload: @datagram_pressure_workload}, _measurement), do: nil

  defp workload_stream_count(config, measurement),
    do: measurement["stream_count"] || config.stream_count

  defp workload_payload_count(%{workload: @datagram_pressure_workload}, _measurement), do: nil

  defp workload_payload_count(config, measurement),
    do: measurement["payload_count"] || config.payload_count

  defp workload_stream_direction(%{workload: @datagram_pressure_workload}, _measurement), do: nil

  defp workload_stream_direction(%{workload: @mixed_moqt_shaped_workload}, measurement),
    do: measurement["stream_direction"] || "mixed"

  defp workload_stream_direction(config, measurement),
    do: measurement["stream_direction"] || config.stream_direction

  defp workload_payload_size(%{workload: @datagram_pressure_workload} = config),
    do: config.datagram_size

  defp workload_payload_size(config), do: config.payload_size

  defp workload_datagram_size(%{workload: @datagram_pressure_workload}, measurement),
    do: measurement["datagram_size_bytes"]

  defp workload_datagram_size(_config, _measurement), do: nil

  defp workload_datagram_rate(%{workload: @datagram_pressure_workload}, measurement) do
    number(measurement["target_datagrams_per_second"]) ||
      measurement["send_rate_datagrams_per_second"]
  end

  defp workload_datagram_rate(_config, _measurement), do: nil

  defp payloads_per_second(nil, _payload_count, _duration_seconds), do: nil
  defp payloads_per_second(_stream_count, nil, _duration_seconds), do: nil

  defp payloads_per_second(stream_count, payload_count, duration_seconds) do
    rate(stream_count * payload_count, duration_seconds)
  end

  defp methodology_metadata(ctx) do
    measurement = measurement(ctx)

    %{
      "warmup_seconds" => 0,
      "step_seconds" => seconds(measurement["application_duration_ms"]),
      "active_send_seconds" => seconds(measurement["send_duration_ms"]),
      "target_send_seconds" => seconds(measurement["target_send_duration_ms"]),
      "scheduled_send_span_seconds" => seconds(measurement["scheduled_send_span_ms"]),
      "total_observation_seconds" => seconds(measurement["application_duration_ms"]),
      "timeout_seconds" => ctx.timeout_ms / 1000,
      "cooldown_seconds" => 0,
      "step_index" => 1,
      "step_count" => 1,
      "repetition_index" => 1,
      "repetition_count" => 1,
      "stop_conditions" => ["reference_comparison_nonzero_exit", @timeout_stop_condition]
    }
  end

  defp metrics(ctx) do
    measurement = measurement(ctx)
    datagram? = ctx.config.workload == @datagram_pressure_workload

    latencies =
      non_null(measurement["stream_latency_ms"]) || non_null(measurement["datagram_latency_ms"]) ||
        %{}

    ctx
    |> base_metrics(measurement, latencies, datagram?)
    |> Map.merge(datagram_metrics(datagram?, measurement))
  end

  defp base_metrics(ctx, measurement, latencies, datagram?) do
    pacing_lag = measurement["send_pacing_lag_ms"] || %{}
    send_call = measurement["send_datagram_call_ms"] || %{}
    stream_send_call = measurement["send_stream_call_ms"] || %{}

    %{
      "handshake_latency_ms" => number(measurement["handshake_latency_ms"]),
      "first_byte_latency_ms" => number(measurement["first_byte_latency_ms"]),
      "offered_load_bps" =>
        number(measurement["offered_load_bps"]) || offered_load_bps(ctx.config),
      "goodput_bps" => number(measurement["goodput_bps"]),
      "send_rate_packets_per_second" => send_rate_packets_per_second(measurement),
      "send_duration_ms" => number(measurement["send_duration_ms"]),
      "target_send_duration_ms" => number(measurement["target_send_duration_ms"]),
      "scheduled_send_span_ms" => number(measurement["scheduled_send_span_ms"]),
      "send_pacing_late_count" => number(measurement["send_pacing_late_count"]),
      "send_pacing_lag_p50_ms" => number(pacing_lag["p50"]),
      "send_pacing_lag_p95_ms" => number(pacing_lag["p95"]),
      "send_pacing_lag_p99_ms" => number(pacing_lag["p99"]),
      "send_datagram_call_slow_count" => number(measurement["send_datagram_call_slow_count"]),
      "send_datagram_call_slow_threshold_ms" =>
        number(measurement["send_datagram_call_slow_threshold_ms"]),
      "send_datagram_call_total_ms" => number(measurement["send_datagram_call_total_ms"]),
      "send_datagram_call_p50_ms" => number(send_call["p50"]),
      "send_datagram_call_p95_ms" => number(send_call["p95"]),
      "send_datagram_call_p99_ms" => number(send_call["p99"]),
      "send_datagram_call_p999_ms" => number(send_call["p999"]),
      "send_datagram_call_max_ms" => number(send_call["max"]),
      "send_stream_call_total_ms" => number(stream_send_call["total"]),
      "send_stream_call_mean_ms" => number(stream_send_call["mean"]),
      "send_stream_call_p50_ms" => number(stream_send_call["p50"]),
      "send_stream_call_p95_ms" => number(stream_send_call["p95"]),
      "send_stream_call_p99_ms" => number(stream_send_call["p99"]),
      "send_stream_call_p999_ms" => number(stream_send_call["p999"]),
      "send_stream_call_max_ms" => number(stream_send_call["max"]),
      "datagram_late_count" => number(measurement["send_pacing_late_count"]),
      "stream_count" => stream_count_metric(datagram?, measurement, ctx.config),
      "payload_size_bytes" =>
        number(measurement["payload_size_bytes"]) || workload_payload_size(ctx.config),
      "latency_p50_ms" => number(latencies["p50"]),
      "latency_p95_ms" => number(latencies["p95"]),
      "latency_p99_ms" => number(latencies["p99"]),
      "sender_cpu_percent" => nil,
      "receiver_cpu_percent" => nil,
      "sender_memory_bytes" => nil,
      "receiver_memory_bytes" => nil,
      "sender_mailbox_depth" => sender_mailbox_depth(measurement),
      "receiver_mailbox_depth" => receiver_mailbox_depth(ctx.config, measurement),
      "send_backpressure_ms" => nil,
      "stream_stall_count" => stream_stall_count(ctx, datagram?),
      "control_latency_p99_ms" => control_latency_p99_ms(measurement),
      "bytes_sent" => number(measurement["bytes_sent"]),
      "bytes_received" => number(measurement["bytes_received"]),
      "reference_comparison_exit_status" => ctx.exit_status
    }
  end

  defp datagram_metrics(true, measurement) do
    %{
      "send_rate_datagrams_per_second" => number(measurement["send_rate_datagrams_per_second"]),
      "offered_rate_ratio" => number(measurement["offered_rate_ratio"]),
      "delivered_datagrams_per_second" => delivered_datagrams_per_second(measurement),
      "datagram_delivery_ratio" => number(measurement["datagram_delivery_ratio"]),
      "datagram_drop_count" => number(measurement["datagram_drop_count"])
    }
  end

  defp datagram_metrics(false, _measurement) do
    %{
      "send_rate_datagrams_per_second" => nil,
      "offered_rate_ratio" => nil,
      "delivered_datagrams_per_second" => nil,
      "datagram_delivery_ratio" => nil,
      "datagram_drop_count" => nil
    }
  end

  defp stream_count_metric(true, _measurement, _config), do: nil

  defp stream_count_metric(false, measurement, config),
    do: number(measurement["stream_count"]) || config.stream_count

  defp sender_mailbox_depth(%{"diagnostics" => %{"process" => process}}) when is_map(process) do
    number(process["message_queue_len"])
  end

  defp sender_mailbox_depth(_measurement), do: nil

  defp receiver_mailbox_depth(
         %{topology: @moqx_client_topology, workload: @datagram_pressure_workload},
         %{"diagnostics" => %{"process" => process}}
       )
       when is_map(process) do
    number(process["message_queue_len"])
  end

  defp receiver_mailbox_depth(_config, _measurement), do: nil

  defp send_rate_packets_per_second(measurement) do
    number(measurement["send_rate_packets_per_second"]) ||
      number(measurement["send_rate_datagrams_per_second"])
  end

  defp control_latency_p99_ms(%{"control_latency_ms" => %{"p99" => p99}}), do: number(p99)
  defp control_latency_p99_ms(_measurement), do: nil

  defp delivered_datagrams_per_second(%{
         "datagrams_received" => received,
         "application_duration_ms" => duration_ms
       }) do
    rate(number(received), seconds(duration_ms))
  end

  defp delivered_datagrams_per_second(_measurement), do: nil

  defp stream_stall_count(_ctx, true), do: nil
  defp stream_stall_count(ctx, false), do: if(ctx.exit_status == 0, do: 0, else: nil)

  defp limits(ctx) do
    failed? = ctx.exit_status != 0 && !ctx.timed_out?

    invalid_measurement? =
      ctx.exit_status == 0 && !valid_measurement?(ctx.config, ctx.measurement)

    datagram_loss? = datagram_loss?(ctx, failed?, invalid_measurement?)
    datagram_send_failure? = datagram_send_failure?(ctx)
    stream_failure? = stream_failure?(ctx)

    %{
      "first_break_symptom" =>
        first_symptom(
          ctx.timed_out?,
          failed?,
          datagram_send_failure?,
          invalid_measurement?,
          datagram_loss?,
          stream_failure?
        ),
      "stopped_by" =>
        stopped_by(
          ctx.timed_out?,
          failed?,
          datagram_send_failure?,
          invalid_measurement?,
          datagram_loss?,
          stream_failure?
        ),
      "connection_closed" => false,
      "protocol_error" =>
        failed? || invalid_measurement? || datagram_send_failure? || stream_failure?,
      "throughput_plateau" => false,
      "latency_explosion" => false,
      "mailbox_growth_without_recovery" => false,
      "cpu_saturation" => false,
      "memory_saturation" => false,
      "control_traffic_delayed" => false
    }
  end

  defp datagram_loss?(ctx, failed?, invalid_measurement?) do
    ratio = number(measurement(ctx)["datagram_delivery_ratio"])

    ctx.config.workload == @datagram_pressure_workload and !failed? and !invalid_measurement? and
      is_number(ratio) and ratio < ctx.config.delivery_threshold
  end

  defp errors(ctx) do
    %{
      "close_reason" => if(ctx.timed_out?, do: "timeout", else: nil),
      "error_code" => ctx.exit_status,
      "message" => error_message(ctx),
      "details" => failure_details(ctx)
    }
  end

  defp error_message(ctx) do
    timed_out_message(ctx) ||
      stream_failure_message(measurement(ctx)["stream_failure"]) ||
      datagram_send_failure_message(measurement(ctx)["datagram_failure"]) ||
      exit_status_message(ctx) ||
      offered_rate_invalid_message(ctx) ||
      invalid_measurement_message(ctx)
  end

  defp timed_out_message(%{timed_out?: true} = ctx),
    do: "reference comparison step timed out after #{seconds(ctx.timeout_ms)}s"

  defp timed_out_message(_ctx), do: nil

  defp exit_status_message(%{exit_status: 0}), do: nil

  defp exit_status_message(ctx) do
    failure_output(ctx.step_output) ||
      "reference comparison step exited with status #{ctx.exit_status}"
  end

  defp offered_rate_invalid_message(ctx) do
    if offered_rate_invalid?(ctx.config, ctx.measurement) do
      "reference comparison offered rate below tolerance: actual/target #{number(measurement(ctx)["offered_rate_ratio"])} < #{ctx.config.offered_rate_tolerance}"
    end
  end

  defp invalid_measurement_message(ctx) do
    unless valid_measurement?(ctx.config, ctx.measurement) do
      "reference comparison step did not produce a valid client_run measurement"
    end
  end

  defp stream_failure?(ctx), do: is_map(measurement(ctx)["stream_failure"])
  defp datagram_send_failure?(ctx), do: is_map(measurement(ctx)["datagram_failure"])

  defp failure_details(ctx) do
    measurement(ctx)["stream_failure"] || measurement(ctx)["datagram_failure"]
  end

  defp stream_failure_message(nil), do: nil

  defp stream_failure_message(failure) do
    "moqx bidirectional stream failed during #{failure["phase"]}: " <>
      "reason=#{failure["reason"]} stream=#{failure["stream_index"]} " <>
      "received=#{failure["bytes_received"]}/#{failure["bytes_expected"]}"
  end

  defp datagram_send_failure_message(nil), do: nil

  defp datagram_send_failure_message(failure) do
    "moqx datagram send failed: #{failure["reason"]}"
  end

  defp first_symptom(
         timed_out?,
         failed?,
         datagram_send_failure?,
         invalid_measurement?,
         datagram_loss?,
         stream_failure?
       ) do
    cond do
      timed_out? -> "step_timeout"
      failed? -> "protocol_error"
      datagram_send_failure? -> "datagram_send_error"
      invalid_measurement? -> "tool_output_invalid"
      datagram_loss? -> "datagram_delivery_loss"
      stream_failure? -> "stream_closed_before_expected_bytes"
      true -> nil
    end
  end

  defp stopped_by(
         timed_out?,
         failed?,
         datagram_send_failure?,
         invalid_measurement?,
         datagram_loss?,
         stream_failure?
       ) do
    cond do
      timed_out? -> @timeout_stop_condition
      failed? -> "reference_comparison_nonzero_exit"
      datagram_send_failure? -> "datagram_send_error"
      invalid_measurement? -> "reference_comparison_invalid_measurement"
      datagram_loss? -> "datagram_delivery_loss"
      stream_failure? -> "stream_closed_before_expected_bytes"
      true -> nil
    end
  end

  defp diagnostics(ctx), do: measurement(ctx)["diagnostics"]

  defp measurement(%{measurement: measurement}) when is_map(measurement), do: measurement
  defp measurement(_ctx), do: %{}

  defp non_null(:null), do: nil
  defp non_null(value), do: value

  defp valid_measurement?(
         %{topology: @reference_client_topology} = config,
         %{"schema_version" => "quicprobe-v1", "record_type" => "client_run"} = measurement
       ),
       do: valid_offered_rate?(config, measurement)

  defp valid_measurement?(
         %{topology: @reference_client_moqx_listener_topology} = config,
         %{"schema_version" => "quicprobe-v1", "record_type" => "client_run"} = measurement
       ),
       do: valid_offered_rate?(config, measurement)

  defp valid_measurement?(
         %{topology: @moqx_client_topology} = config,
         %{"schema_version" => "moqx-reference-measurement-v1", "record_type" => "client_run"} =
           measurement
       ),
       do: valid_offered_rate?(config, measurement)

  defp valid_measurement?(_config, _measurement), do: false

  defp write_records(records, nil) do
    Enum.each(records, fn record ->
      record
      |> encode_json()
      |> IO.iodata_to_binary()
      |> IO.puts()
    end)
  end

  defp write_records(records, path) do
    body =
      Enum.map_join(records, "\n", fn record ->
        record
        |> encode_json()
        |> IO.iodata_to_binary()
      end)

    File.write!(path, body <> "\n")
  end

  defp encode_json(value), do: value |> json_ready() |> :json.encode()

  defp json_ready(nil), do: :null
  defp json_ready(:null), do: :null
  defp json_ready(value) when value in [true, false], do: value

  defp json_ready(value) when is_map(value) do
    Map.new(value, fn {key, map_value} -> {key, json_ready(map_value)} end)
  end

  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value), do: value

  defp decode_json(""), do: nil

  defp decode_json(output) do
    output
    |> extract_json_object()
    |> :json.decode()
  rescue
    _ -> nil
  end

  defp extract_json_object(output) do
    with {start, _} <- :binary.match(output, "{"),
         matches when matches != [] <- :binary.matches(output, "}"),
         {finish, _} <- List.last(matches) do
      binary_part(output, start, finish - start + 1)
    else
      _ -> output
    end
  end

  defp number(value) when is_integer(value) or is_float(value), do: value
  defp number(_value), do: nil

  defp rate(count, seconds) when not is_number(count) or not is_number(seconds) or seconds <= 0,
    do: nil

  defp rate(count, seconds), do: count / seconds

  defp ratio(count, total) when not is_number(count) or not is_number(total) or total <= 0,
    do: nil

  defp ratio(count, total), do: count / total

  defp paced_datagrams?(%{datagram_rate: rate}) when is_integer(rate) and rate > 0, do: true
  defp paced_datagrams?(_config), do: false

  defp datagram_mode(config), do: if(paced_datagrams?(config), do: "paced", else: "burst")

  defp datagram_pacing(%{workload: @datagram_pressure_workload} = config),
    do: datagram_mode(config)

  defp datagram_pacing(_config), do: nil

  defp profile_datagram_mode(%{workload: @datagram_pressure_workload} = config),
    do: datagram_mode(config)

  defp profile_datagram_mode(_config), do: nil

  defp target_datagram_rate(config),
    do: if(paced_datagrams?(config), do: config.datagram_rate, else: nil)

  defp target_duration_seconds(config),
    do: if(paced_datagrams?(config), do: config.duration_seconds, else: nil)

  defp target_rate_ratio(send_rate, config) do
    case target_datagram_rate(config) do
      target when is_number(target) and is_number(send_rate) and target > 0 ->
        send_rate / target

      _ ->
        nil
    end
  end

  defp offered_rate_valid?(_ratio, %{datagram_rate: nil}), do: true

  defp offered_rate_valid?(ratio, config) when is_number(ratio),
    do: ratio >= config.offered_rate_tolerance

  defp offered_rate_valid?(_ratio, _config), do: false

  defp valid_offered_rate?(config, measurement),
    do: !offered_rate_invalid?(config, measurement)

  defp offered_rate_invalid?(
         %{workload: @datagram_pressure_workload, datagram_rate: rate},
         %{"datagram_mode" => "paced"} = measurement
       )
       when is_integer(rate) and rate > 0 do
    case measurement["offered_rate_valid"] do
      true -> false
      false -> true
      _ -> true
    end
  end

  defp offered_rate_invalid?(_config, _measurement), do: false

  defp effective_datagram_count(config) do
    if paced_datagrams?(config) do
      config.datagram_rate * config.duration_seconds
    else
      config.datagram_count
    end
  end

  defp offered_load_bps(%{workload: @datagram_pressure_workload} = config) do
    case target_datagram_rate(config) do
      nil -> nil
      rate -> rate * config.datagram_size * 8
    end
  end

  defp offered_load_bps(_config), do: nil

  defp control_trickle_bps(%{workload: @mixed_moqt_shaped_workload} = config) do
    config.control_rate * config.control_payload_size * 8
  end

  defp control_trickle_bps(_config), do: nil

  defp datagram_receive_timeout_ms(%{workload: @datagram_pressure_workload} = config) do
    datagram_client_timeout_seconds(config) * 1000
  end

  defp datagram_receive_timeout_ms(config), do: client_timeout_ms(config)

  defp seconds(nil), do: nil

  defp seconds(milliseconds) when is_integer(milliseconds) and rem(milliseconds, 1000) == 0 do
    div(milliseconds, 1000)
  end

  defp seconds(milliseconds) when is_number(milliseconds), do: milliseconds / 1000

  defp binary_payload(size), do: :binary.copy(<<0>>, size)

  defp bits_per_second(bytes, duration_ms) when is_number(bytes) and duration_ms > 0 do
    bytes * 8 * 1000 / duration_ms
  end

  defp bits_per_second(_bytes, _duration_ms), do: nil

  defp latency_summary(values) do
    sorted = Enum.sort(values)

    %{
      "p50" => percentile(sorted, 0.50),
      "p95" => percentile(sorted, 0.95),
      "p99" => percentile(sorted, 0.99)
    }
  end

  defp duration_summary_ms(values_us) do
    values_ms = Enum.map(values_us, &(&1 / 1000))
    sorted = Enum.sort(values_ms)
    count = length(sorted)
    total = Enum.sum(sorted)

    %{
      "count" => count,
      "total" => total,
      "mean" => mean(total, count),
      "p50" => percentile(sorted, 0.50),
      "p95" => percentile(sorted, 0.95),
      "p99" => percentile(sorted, 0.99),
      "p999" => percentile(sorted, 0.999),
      "max" => List.last(sorted)
    }
  end

  defp mean(_total, 0), do: nil
  defp mean(total, count), do: total / count

  defp percentile([], _p), do: nil
  defp percentile([value], _p), do: value

  defp percentile(sorted, p) do
    index = trunc((length(sorted) - 1) * p)
    Enum.at(sorted, index)
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
  defp elapsed_ms(started_at), do: (monotonic_us() - started_at) / 1000

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc when is_map(value) ->
        compacted = compact(value)
        if compacted == %{}, do: acc, else: Map.put(acc, key, compacted)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp command_string(script, argv), do: Enum.join([script | argv], " ")

  defp default_run_id(topology, server) do
    timestamp()
    |> String.replace(":", "-")
    |> String.replace(".", "-")
    |> Kernel.<>("-#{topology}-#{server}")
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      _ -> nil
    end
  end

  defp os_description do
    case :os.type() do
      {:unix, :darwin} -> command_output("sw_vers", ["-productVersion"])
      {:unix, _} -> linux_pretty_name() || command_output("uname", ["-s"])
      other -> inspect(other)
    end
  end

  defp linux_pretty_name do
    with {:ok, text} <- File.read("/etc/os-release"),
         [_, value] <- Regex.run(~r/PRETTY_NAME="?([^"\n]+)"?/, text) do
      value
    else
      _ -> nil
    end
  end

  defp kernel, do: command_output("uname", ["-r"])

  defp cpu_model do
    case :os.type() do
      {:unix, :darwin} -> command_output("sysctl", ["-n", "machdep.cpu.brand_string"])
      {:unix, _} -> linux_cpu_model()
      _ -> nil
    end
  end

  defp linux_cpu_model do
    with {:ok, text} <- File.read("/proc/cpuinfo"),
         [_, value] <- Regex.run(~r/model name\s*:\s*(.+)/, text) do
      value
    else
      _ -> nil
    end
  end

  defp memory_bytes do
    case :os.type() do
      {:unix, :darwin} -> command_output("sysctl", ["-n", "hw.memsize"]) |> parse_int()
      {:unix, _} -> linux_memory_bytes()
      _ -> nil
    end
  end

  defp linux_memory_bytes do
    with {:ok, text} <- File.read("/proc/meminfo"),
         [_, kib] <- Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, text),
         {value, ""} <- Integer.parse(kib) do
      value * 1024
    else
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(text) do
    case Integer.parse(String.trim(text)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp moqx_version, do: app_version(:moqx)

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      version -> List.to_string(version)
    end
  end

  defp command_output(command, args) do
    case System.find_executable(command) do
      nil ->
        nil

      _path ->
        case System.cmd(command, args, stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _ -> nil
        end
    end
  end

  defp failure_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> case do
      "" -> nil
      message -> message
    end
  end

  defp failure_output(_output), do: nil

  defp loopback?(server), do: server in ["localhost", "127.0.0.1", "::1"]

  defp usage(script) do
    """
    Usage:
      #{script} --topology TOPOLOGY --server HOST --ca PATH [options]

    Required:
      --topology VALUE               one of:
                                      reference-client-to-reference-server
                                      reference-client-to-moqx-listener
                                      moqx-client-to-reference-server
      --server HOST                  peer server host or IP
      --ca PATH                      CA certificate for the peer server

    Common options:
      --port PORT                    reference server UDP port (default: 4433)
      --alpn VALUE                   QUIC ALPN (default: moqx-test)
      --servername VALUE             TLS server name override
      --workload VALUE               stream_pressure, datagram_pressure, or mixed_moqt_shaped (default: stream_pressure)
      --stream-direction VALUE       bidirectional or unidirectional (default: bidirectional)
      --stream-count N               concurrent streams (default: 1)
      --stream-send-window N         max in-flight sends per MOQX stream (default: #{@default_stream_send_window})
      --stream-event-batch-size N    ready events to drain after each blocking receive (default: #{@default_stream_event_batch_size})
      --stream-diagnostics-sampling VALUE
                                     event sampler or final diagnostics snapshot for MOQX streams (default: event)
      --payload-size BYTES           bytes per payload write (default: 1200)
      --payload-count N              payload writes per stream (default: 1)
      --datagram-size BYTES          bytes per datagram for datagram_pressure (default: 1200)
      --datagram-count N             datagrams to send for datagram_pressure (default: 1000)
      --datagram-rate N              target datagrams/sec for paced datagram_pressure
      --duration-seconds N           paced datagram_pressure duration; offered = rate * duration
      --control-payload-size BYTES   bytes per control message for mixed_moqt_shaped (default: 64)
      --control-message-count N      control messages for mixed_moqt_shaped (default: 10)
      --control-rate N               target control messages/sec for mixed_moqt_shaped (default: 10)
      --delivery-threshold RATIO     minimum acceptable delivery ratio before loss stop (default: 1.0)
      --offered-rate-tolerance RATIO minimum actual/target offered rate for paced steps (default: 0.95)
      --timeout-seconds N            client timeout (default: 5)
      --timeout-margin-seconds N     kill/abort step after timeout + N seconds (default: 2)
      --quicprobe-command PATH       quicprobe executable for reference-client topologies (default: quicprobe)
      --path-json PATH_OR_JSON       path metadata file or inline JSON object
      --output PATH                  write JSONL to a file instead of stdout
      --run-id ID                    run identifier

    Metadata overrides:
      --evidence-tier VALUE
      --path-id VALUE
      --client-host-id VALUE
      --server-host-id VALUE
      --client-provider VALUE
      --server-provider VALUE
      --client-region VALUE
      --server-region VALUE
      --client-instance-class VALUE
      --server-instance-class VALUE
      --client-network-class VALUE
      --server-network-class VALUE

    Local smoke:
      #{script} \\
        --topology reference-client-to-reference-server \\
        --server 127.0.0.1 --port 4433 --ca .tmp/integration-certs/ca.pem \\
        --quicprobe-command /path/to/quicprobe --stream-count 2

      #{script} \\
        --topology moqx-client-to-reference-server \\
        --server 127.0.0.1 --port 4433 --ca .tmp/integration-certs/ca.pem \\
        --servername localhost --stream-count 2

      #{script} \\
        --topology reference-client-to-reference-server \\
        --workload datagram_pressure \\
        --server 127.0.0.1 --port 4433 --ca .tmp/integration-certs/ca.pem \\
        --quicprobe-command /path/to/quicprobe \\
        --datagram-size 1200 --datagram-count 1000

      #{script} \\
        --topology reference-client-to-reference-server \\
        --workload datagram_pressure \\
        --server 127.0.0.1 --port 4433 --ca .tmp/integration-certs/ca.pem \\
        --quicprobe-command /path/to/quicprobe \\
        --datagram-size 1200 --datagram-rate 1000 --duration-seconds 10

    Reference client to MOQX listener:
      server$ moqx-transport-bench moqx-listener \\
        --host 0.0.0.0 --port 4433 \\
        --certfile /opt/moqx-bench/certs/server.pem \\
        --keyfile /opt/moqx-bench/certs/server-key.pem \\
        --stream-count 2

      client$ #{script} \\
        --topology reference-client-to-moqx-listener \\
        --workload datagram_pressure \\
        --server SERVER_PRIVATE_IP --port 4433 \\
        --ca /opt/moqx-bench/certs/ca.pem \\
        --quicprobe-command /opt/moqx-bench/quicprobe/current/bin/quicprobe \\
        --datagram-size 1200 --datagram-count 1000
    """
  end
end
