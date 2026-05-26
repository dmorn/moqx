defmodule MOQX.TransportBench.ReferenceComparison do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.TransportBench.BuildInfo
  alias MOQX.TransportBench.DatagramPayload
  alias MOQX.TransportBench.PathMetadata

  @default_script "moqx-transport-bench reference-comparison"
  @script_version "v1"
  @schema_version "transport-bench-v1"
  @timeout_exit_status 124
  @timeout_stop_condition "reference_comparison_step_timeout"
  @datagram_header_size DatagramPayload.header_size()
  @stream_pressure_workload "stream_pressure"
  @datagram_pressure_workload "datagram_pressure"
  @stream_send_window 16
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
          payload_size: :integer,
          payload_count: :integer,
          datagram_size: :integer,
          datagram_count: :integer,
          datagram_rate: :integer,
          duration_seconds: :integer,
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
      payload_size: Keyword.get(opts, :payload_size, 1200),
      payload_count: Keyword.get(opts, :payload_count, 1),
      datagram_size: Keyword.get(opts, :datagram_size, 1200),
      datagram_count: Keyword.get(opts, :datagram_count, 1000),
      datagram_rate: opts[:datagram_rate],
      duration_seconds: opts[:duration_seconds],
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
         :ok <- validate_positive(config.payload_size, "--payload-size"),
         :ok <- validate_positive(config.payload_count, "--payload-count"),
         :ok <- validate_datagram_size(config),
         :ok <- validate_positive(config.datagram_count, "--datagram-count"),
         :ok <- validate_paced_datagrams(config),
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

    if config.servername do
      args ++ ["--servername", config.servername]
    else
      args
    end
  end

  defp run_moqx_client(config) do
    args = moqx_client_step_args(config)
    timeout_ms = step_timeout_ms(config)
    {diagnostics_agent, config} = maybe_start_diagnostics_agent(config)

    try do
      task =
        Task.async(fn ->
          do_run_moqx_client(config)
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, {:ok, measurement}} ->
          {measurement, "", 0, args, false, timeout_ms}

        {:ok, {:error, message}} ->
          measurement = diagnostic_measurement(config, diagnostics_agent)
          {measurement, message, 1, args, false, timeout_ms}

        nil ->
          measurement = diagnostic_measurement(config, diagnostics_agent)
          _result = Task.shutdown(task, :brutal_kill)
          {measurement, "", @timeout_exit_status, args, true, timeout_ms}
      end
    after
      stop_diagnostics_agent(diagnostics_agent)
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

  defp maybe_start_diagnostics_agent(%{topology: @moqx_client_topology} = config) do
    case Agent.start_link(fn -> initial_diagnostics(config) end) do
      {:ok, agent} -> {agent, Map.put(config, :diagnostics_agent, agent)}
      {:error, _reason} -> {nil, config}
    end
  end

  defp maybe_start_diagnostics_agent(config), do: {nil, config}

  defp stop_diagnostics_agent(nil), do: :ok

  defp stop_diagnostics_agent(agent) do
    if Process.alive?(agent), do: Agent.stop(agent), else: :ok
  end

  defp initial_diagnostics(config) do
    %{
      "version" => "stream-pressure-diagnostics-v1",
      "summary" => %{
        "topology" => config.topology,
        "workload" => config.workload,
        "stream_direction" => config.stream_direction,
        "stream_count" => config.stream_count,
        "payload_size_bytes" => config.payload_size,
        "payload_count" => config.payload_count
      },
      "streams" => %{},
      "process" => %{}
    }
  end

  defp diagnostic_measurement(config, nil), do: diagnostic_measurement(config, %{})

  defp diagnostic_measurement(config, diagnostics_agent) when is_pid(diagnostics_agent) do
    diagnostics =
      if Process.alive?(diagnostics_agent) do
        Agent.get(diagnostics_agent, & &1)
      else
        %{}
      end

    diagnostic_measurement(config, diagnostics)
  end

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

  defp record_diagnostics_summary(%{diagnostics_agent: agent}, summary) when is_pid(agent) do
    Agent.update(agent, fn diagnostics ->
      update_in(diagnostics, ["summary"], &Map.merge(&1 || %{}, summary))
    end)
  end

  defp record_diagnostics_summary(_config, _summary), do: :ok

  defp record_stream_phase(config, stream_state, phase, attrs \\ %{})

  defp record_stream_phase(%{diagnostics_agent: agent}, stream_state, phase, attrs)
       when is_pid(agent) do
    diagnostic =
      stream_diagnostic(
        stream_state,
        Map.get(attrs, "bytes_expected", stream_state.bytes_sent),
        Map.get(attrs, "bytes_received", 0),
        phase,
        attrs
      )

    Agent.update(agent, fn diagnostics ->
      diagnostics
      |> put_in(["streams", stream_state.index], diagnostic)
      |> update_in(["summary"], fn summary ->
        summary
        |> Map.put("last_phase", phase)
        |> Map.put("bytes_sent", summary_bytes_sent(diagnostics, diagnostic))
        |> Map.put("bytes_received", summary_bytes_received(diagnostics, diagnostic))
      end)
    end)
  end

  defp record_stream_phase(_config, _stream_state, _phase, _attrs), do: :ok

  defp record_scheduled_streams(config, streams, payload) do
    expected_bytes = byte_size(payload) * config.payload_count

    Enum.each(streams, fn stream_state ->
      record_stream_phase(config, stream_state, "send_fin_scheduled", %{
        "bytes_expected" => expected_bytes
      })
    end)
  end

  defp summary_bytes_sent(diagnostics, diagnostic) do
    diagnostics
    |> Map.get("streams", %{})
    |> Map.put(diagnostic["index"], diagnostic)
    |> Map.values()
    |> Enum.map(&(&1["bytes_sent"] || 0))
    |> Enum.sum()
  end

  defp summary_bytes_received(diagnostics, diagnostic) do
    diagnostics
    |> Map.get("streams", %{})
    |> Map.put(diagnostic["index"], diagnostic)
    |> Map.values()
    |> Enum.map(&(&1["bytes_received"] || 0))
    |> Enum.sum()
  end

  defp process_diagnostics do
    message_queue_len =
      case Process.info(self(), :message_queue_len) do
        {:message_queue_len, value} -> value
        nil -> nil
      end

    %{"message_queue_len" => message_queue_len}
  end

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

  defp measure_moqx_stream_pressure(ctx, connection, config, handshake_latency_ms) do
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
      "payload_size_bytes" => config.payload_size,
      "payload_count" => config.payload_count,
      "bytes_sent" => result.bytes_sent,
      "bytes_received" => result.bytes_received,
      "handshake_latency_ms" => handshake_latency_ms,
      "first_byte_latency_ms" => first_byte_latency_ms,
      "application_duration_ms" => application_duration_ms,
      "goodput_bps" => bits_per_second(bytes_for_goodput, application_duration_ms),
      "stream_latency_ms" => latency_summary(result.stream_latencies_ms),
      "send_rate_packets_per_second" =>
        rate(config.stream_count * config.payload_count, seconds(application_duration_ms)),
      "stream_scheduling" => "concurrent",
      "stream_failure" => result.failure,
      "diagnostics" =>
        stream_pressure_diagnostics(config, streams, result, application_duration_ms)
    }
  end

  defp measure_moqx_datagram_pressure(ctx, connection, config, handshake_latency_ms) do
    application_started_at = monotonic_us()
    offered = effective_datagram_count(config)

    {accepted, send_duration_ms, received, first_byte_latency_ms, latencies, _ctx} =
      send_and_receive_moqx_datagrams(ctx, connection, config, offered, application_started_at)

    received_count = MapSet.size(received)
    application_duration_ms = elapsed_ms(application_started_at)
    bytes_sent = accepted * config.datagram_size
    bytes_received = received_count * config.datagram_size
    send_rate = rate(accepted, seconds(send_duration_ms))
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
      "datagram_count" => offered,
      "datagram_mode" => datagram_mode(config),
      "target_datagrams_per_second" => target_datagram_rate(config),
      "target_duration_seconds" => target_duration_seconds(config),
      "delivery_threshold" => config.delivery_threshold,
      "offered_rate_ratio" => offered_rate_ratio,
      "offered_rate_tolerance" => config.offered_rate_tolerance,
      "offered_rate_valid" => offered_rate_valid?(offered_rate_ratio, config),
      "datagrams_offered" => offered,
      "datagrams_accepted" => accepted,
      "datagrams_received" => received_count,
      "datagram_delivery_ratio" => ratio(received_count, offered),
      "datagram_drop_count" => offered - received_count,
      "bytes_sent" => bytes_sent,
      "bytes_received" => bytes_received,
      "handshake_latency_ms" => handshake_latency_ms,
      "first_byte_latency_ms" => first_byte_latency_ms,
      "application_duration_ms" => application_duration_ms,
      "offered_load_bps" => offered_load_bps(config),
      "goodput_bps" => bits_per_second(bytes_received, application_duration_ms),
      "send_rate_packets_per_second" => send_rate,
      "send_rate_datagrams_per_second" => send_rate,
      "datagram_latency_ms" => latency_summary(latencies)
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

    {accepted, ctx, received, latencies, first_byte, _next_send_at} =
      Enum.reduce(
        1..count,
        {0, ctx, MapSet.new(), [], nil, send_started_at},
        fn sequence, {accepted, ctx, received, latencies, first_byte, next_send_at} ->
          {received, first_byte, latencies, ctx} =
            receive_moqx_datagrams_until(
              ctx,
              connection,
              received,
              latencies,
              first_byte,
              started_at,
              next_send_at
            )

          {:ok, ctx} =
            Transport.send_datagram(
              ctx,
              connection,
              DatagramPayload.encode(sequence, config.datagram_size, monotonic_us())
            )

          {received, first_byte, latencies, ctx} =
            drain_available_moqx_datagrams(
              ctx,
              connection,
              received,
              latencies,
              first_byte,
              started_at
            )

          {accepted + 1, ctx, received, latencies, first_byte, next_send_at + interval_us}
        end
      )

    send_duration_ms = elapsed_ms(send_started_at)

    {received, first_byte, latencies, ctx} =
      receive_moqx_datagrams(
        ctx,
        connection,
        config,
        count,
        received,
        latencies,
        first_byte,
        started_at
      )

    {accepted, send_duration_ms, received, first_byte, latencies, ctx}
  end

  defp send_and_receive_moqx_datagrams(ctx, connection, config, count, started_at) do
    {accepted, send_duration_ms, ctx} = send_moqx_datagrams(ctx, connection, config, count)

    {received, first_byte, latencies, ctx} =
      receive_moqx_datagrams(
        ctx,
        connection,
        config,
        count,
        MapSet.new(),
        [],
        nil,
        started_at
      )

    {accepted, send_duration_ms, received, first_byte, latencies, ctx}
  end

  defp send_moqx_datagrams(ctx, connection, config, count) do
    started_at = monotonic_us()

    {accepted, ctx} =
      Enum.reduce(1..count, {0, ctx}, fn sequence, {accepted, ctx} ->
        {:ok, ctx} =
          Transport.send_datagram(
            ctx,
            connection,
            DatagramPayload.encode(sequence, config.datagram_size, monotonic_us())
          )

        {accepted + 1, ctx}
      end)

    {accepted, elapsed_ms(started_at), ctx}
  end

  defp receive_moqx_datagrams_until(
         ctx,
         connection,
         received,
         latencies,
         first_byte,
         started_at,
         target_us
       ) do
    remaining_ms = max(ceil((target_us - monotonic_us()) / 1000), 0)

    case Transport.receive_event(ctx, remaining_ms) do
      {:ok, {:datagram, ^connection, payload, _metadata}, ctx} ->
        {received, latencies, first_byte} =
          record_moqx_datagram(payload, received, latencies, first_byte, started_at)

        receive_moqx_datagrams_until(
          ctx,
          connection,
          received,
          latencies,
          first_byte,
          started_at,
          target_us
        )

      {:ok, _event, ctx} ->
        receive_moqx_datagrams_until(
          ctx,
          connection,
          received,
          latencies,
          first_byte,
          started_at,
          target_us
        )

      {:unknown, _message, ctx} ->
        receive_moqx_datagrams_until(
          ctx,
          connection,
          received,
          latencies,
          first_byte,
          started_at,
          target_us
        )

      {:error, _reason, ctx} ->
        {received, first_byte, latencies, ctx}

      {:timeout, ctx} ->
        {received, first_byte, latencies, ctx}
    end
  end

  defp drain_available_moqx_datagrams(
         ctx,
         connection,
         received,
         latencies,
         first_byte,
         started_at
       ) do
    case Transport.receive_event(ctx, 0) do
      {:ok, {:datagram, ^connection, payload, _metadata}, ctx} ->
        {received, latencies, first_byte} =
          record_moqx_datagram(payload, received, latencies, first_byte, started_at)

        drain_available_moqx_datagrams(
          ctx,
          connection,
          received,
          latencies,
          first_byte,
          started_at
        )

      {:ok, _event, ctx} ->
        drain_available_moqx_datagrams(
          ctx,
          connection,
          received,
          latencies,
          first_byte,
          started_at
        )

      {:unknown, _message, ctx} ->
        drain_available_moqx_datagrams(
          ctx,
          connection,
          received,
          latencies,
          first_byte,
          started_at
        )

      {:error, _reason, ctx} ->
        {received, first_byte, latencies, ctx}

      {:timeout, ctx} ->
        {received, first_byte, latencies, ctx}
    end
  end

  defp receive_moqx_datagrams(
         ctx,
         connection,
         config,
         expected,
         received,
         latencies,
         first_byte,
         started_at
       ) do
    if MapSet.size(received) >= expected or
         elapsed_ms(started_at) >= datagram_receive_timeout_ms(config) do
      {received, first_byte, latencies, ctx}
    else
      receive_moqx_datagram(
        ctx,
        connection,
        config,
        expected,
        received,
        latencies,
        first_byte,
        started_at
      )
    end
  end

  defp receive_moqx_datagram(
         ctx,
         connection,
         config,
         expected,
         received,
         latencies,
         first_byte,
         started_at
       ) do
    remaining_ms = max(datagram_receive_timeout_ms(config) - trunc(elapsed_ms(started_at)), 0)

    case Transport.receive_event(ctx, remaining_ms) do
      {:ok, {:datagram, ^connection, payload, _metadata}, ctx} ->
        {received, latencies, first_byte} =
          record_moqx_datagram(payload, received, latencies, first_byte, started_at)

        receive_moqx_datagrams(
          ctx,
          connection,
          config,
          expected,
          received,
          latencies,
          first_byte,
          started_at
        )

      {:ok, _event, ctx} ->
        receive_moqx_datagrams(
          ctx,
          connection,
          config,
          expected,
          received,
          latencies,
          first_byte,
          started_at
        )

      {:unknown, _message, ctx} ->
        receive_moqx_datagrams(
          ctx,
          connection,
          config,
          expected,
          received,
          latencies,
          first_byte,
          started_at
        )

      {:error, _reason, ctx} ->
        receive_moqx_datagrams(
          ctx,
          connection,
          config,
          expected,
          received,
          latencies,
          first_byte,
          started_at
        )

      {:timeout, ctx} ->
        {received, first_byte, latencies, ctx}
    end
  end

  defp record_moqx_datagram(
         payload,
         received,
         latencies,
         first_byte,
         started_at
       ) do
    case DatagramPayload.decode(payload) do
      {:ok, sequence, sent_at} ->
        if MapSet.member?(received, sequence) do
          {received, latencies, first_byte}
        else
          latency = elapsed_ms(sent_at)
          first_byte = first_byte || elapsed_ms(started_at)
          {MapSet.put(received, sequence), [latency | latencies], first_byte}
        end

      :error ->
        {received, latencies, first_byte}
    end
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
           payloads_scheduled: 0,
           payloads_completed: 0,
           send_inflight: 0,
           send_completed: 0,
           send_cancelled: 0,
           peer_finished?: false,
           failure: nil
         }}
      end)

    {states, ctx} = prime_active_echo_sends(ctx, states, payload, config)
    deadline_us = monotonic_us() + client_timeout_ms(config) * 1000
    collect_active_echo_events(ctx, states, payload, config, first_byte_origin, deadline_us)
  end

  defp collect_active_echo_events(ctx, states, payload, config, first_byte_origin, deadline_us) do
    cond do
      all_streams_complete?(states) ->
        active_echo_result(ctx, states, config)

      failure = first_stream_failure(states) ->
        active_echo_result(ctx, states, config, failure)

      monotonic_us() >= deadline_us ->
        failure = timeout_stream_failure(states, config)
        active_echo_result(ctx, mark_timeout_failure(states, failure), config, failure)

      true ->
        timeout_ms = max(div(deadline_us - monotonic_us(), 1000), 0)

        case Transport.receive_event(ctx, timeout_ms) do
          {:ok, event, ctx} ->
            {states, ctx} =
              handle_active_echo_event(ctx, states, event, payload, config, first_byte_origin)

            collect_active_echo_events(
              ctx,
              states,
              payload,
              config,
              first_byte_origin,
              deadline_us
            )

          {:unknown, _message, ctx} ->
            collect_active_echo_events(
              ctx,
              states,
              payload,
              config,
              first_byte_origin,
              deadline_us
            )

          {:error, reason, ctx} ->
            failure = receive_event_failure(states, config, reason)
            active_echo_result(ctx, mark_timeout_failure(states, failure), config, failure)

          {:timeout, ctx} ->
            failure = timeout_stream_failure(states, config)
            active_echo_result(ctx, mark_timeout_failure(states, failure), config, failure)
        end
    end
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

      state.send_inflight >= @stream_send_window ->
        {state, ctx}

      true ->
        payload_index = state.payloads_scheduled + 1
        finish? = payload_index == config.payload_count
        opts = if finish?, do: [finish: true], else: []

        case Transport.send_stream(ctx, state.stream_state.stream, payload, opts) do
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
                send_inflight: state.send_inflight + 1
            }

            record_stream_phase(config, stream_state, "send_window_open", %{
              "bytes_expected" => expected_stream_bytes(config),
              "payloads_scheduled" => state.payloads_scheduled,
              "send_inflight" => state.send_inflight,
              "send_window" => @stream_send_window
            })

            schedule_active_stream_sends(ctx, state, payload, config)

          {:error, reason, ctx} ->
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
    received = state.bytes_received + byte_count
    first_byte_latency_ms = state.first_byte_latency_ms || elapsed_ms(first_byte_origin)
    completed_at = if received >= expected_stream_bytes(config), do: monotonic_us()
    phase = if completed_at, do: "echo_complete", else: "receiving_echo"

    state = %{
      state
      | bytes_received: received,
        first_byte_latency_ms: first_byte_latency_ms,
        completed_at: completed_at
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

  defp active_echo_result(ctx, states, config, failure \\ nil) do
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
        "peer_finished" => state.peer_finished?,
        "error" => state.failure && state.failure["reason"]
      }
    )
  end

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

    summary =
      %{
        "streams_opened" => length(streams),
        "streams_completed" => count_phase(stream_diagnostics, "echo_complete"),
        "streams_failed" => count_phase(stream_diagnostics, "echo_failed"),
        "payloads_accepted" =>
          stream_diagnostics |> Enum.map(&(&1["payloads_accepted"] || 0)) |> Enum.sum(),
        "bytes_sent" => result.bytes_sent,
        "bytes_expected" => expected_stream_bytes(config) * length(streams),
        "bytes_received" => result.bytes_received,
        "application_duration_ms" => application_duration_ms,
        "failure" => result.failure
      }
      |> compact()

    %{
      "version" => "stream-pressure-diagnostics-v1",
      "summary" => summary,
      "streams" => stream_diagnostics,
      "process" => process_diagnostics()
    }
  end

  defp count_phase(stream_diagnostics, phase) do
    Enum.count(stream_diagnostics, fn diagnostic -> diagnostic["phase"] == phase end)
  end

  defp expected_stream_bytes(config), do: config.payload_size * config.payload_count

  defp stream_diagnostic(stream_state, expected_bytes, received, phase, extra \\ %{}) do
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
  end

  defp stream_id(%{info: %{stream_id: stream_id}}), do: stream_id

  defp stream_direction_name(%{info: %{direction: direction}}) when is_atom(direction),
    do: Atom.to_string(direction)

  defp stream_direction_name(_stream), do: nil

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(reason), do: inspect(reason)

  defp matches_payload?(chunk, payload, offset) do
    chunk
    |> :binary.bin_to_list()
    |> Enum.with_index(offset)
    |> Enum.all?(fn {byte, index} ->
      byte == :binary.at(payload, rem(index, byte_size(payload)))
    end)
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
        "stream_scheduling" => stream_scheduling(ctx.config, measurement)
      }
    }
  end

  defp stream_scheduling(%{workload: @datagram_pressure_workload}, _measurement), do: nil

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
      "family" => "reference_comparison",
      "direction" => "client_to_server",
      "stream_direction" => workload_stream_direction(ctx.config, measurement),
      "stream_count" => stream_count,
      "payload_size_bytes" =>
        measurement["payload_size_bytes"] || workload_payload_size(ctx.config),
      "payloads_per_second" => payloads_per_second(stream_count, payload_count, duration_seconds),
      "offered_load_bps" =>
        number(measurement["offered_load_bps"]) || offered_load_bps(ctx.config),
      "datagram_size_bytes" => measurement["datagram_size_bytes"],
      "datagrams_per_second" =>
        number(measurement["target_datagrams_per_second"]) ||
          measurement["send_rate_datagrams_per_second"],
      "control_trickle_bps" => nil,
      "topology" => ctx.config.topology,
      "tool" => workload_tool(ctx.config),
      "server" => ctx.config.server,
      "port" => ctx.config.port
    }
  end

  defp workload_tool(%{topology: @moqx_client_topology}), do: "moqx"
  defp workload_tool(_config), do: "quicprobe"

  defp workload_stream_count(%{workload: @datagram_pressure_workload}, _measurement), do: nil

  defp workload_stream_count(config, measurement),
    do: measurement["stream_count"] || config.stream_count

  defp workload_payload_count(%{workload: @datagram_pressure_workload}, _measurement), do: nil

  defp workload_payload_count(config, measurement),
    do: measurement["payload_count"] || config.payload_count

  defp workload_stream_direction(%{workload: @datagram_pressure_workload}, _measurement), do: nil

  defp workload_stream_direction(config, measurement),
    do: measurement["stream_direction"] || config.stream_direction

  defp workload_payload_size(%{workload: @datagram_pressure_workload} = config),
    do: config.datagram_size

  defp workload_payload_size(config), do: config.payload_size

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

    %{
      "handshake_latency_ms" => number(measurement["handshake_latency_ms"]),
      "first_byte_latency_ms" => number(measurement["first_byte_latency_ms"]),
      "offered_load_bps" =>
        number(measurement["offered_load_bps"]) || offered_load_bps(ctx.config),
      "goodput_bps" => number(measurement["goodput_bps"]),
      "send_rate_packets_per_second" => send_rate_packets_per_second(measurement),
      "send_rate_datagrams_per_second" => number(measurement["send_rate_datagrams_per_second"]),
      "offered_rate_ratio" => number(measurement["offered_rate_ratio"]),
      "delivered_datagrams_per_second" => delivered_datagrams_per_second(measurement),
      "datagram_delivery_ratio" => number(measurement["datagram_delivery_ratio"]),
      "datagram_drop_count" => number(measurement["datagram_drop_count"]),
      "datagram_late_count" => nil,
      "stream_count" =>
        if(datagram?,
          do: nil,
          else: number(measurement["stream_count"]) || ctx.config.stream_count
        ),
      "payload_size_bytes" =>
        number(measurement["payload_size_bytes"]) || workload_payload_size(ctx.config),
      "latency_p50_ms" => number(latencies["p50"]),
      "latency_p95_ms" => number(latencies["p95"]),
      "latency_p99_ms" => number(latencies["p99"]),
      "sender_cpu_percent" => nil,
      "receiver_cpu_percent" => nil,
      "sender_memory_bytes" => nil,
      "receiver_memory_bytes" => nil,
      "sender_mailbox_depth" => nil,
      "receiver_mailbox_depth" => nil,
      "send_backpressure_ms" => nil,
      "stream_stall_count" => stream_stall_count(ctx, datagram?),
      "control_latency_p99_ms" => nil,
      "bytes_sent" => number(measurement["bytes_sent"]),
      "bytes_received" => number(measurement["bytes_received"]),
      "reference_comparison_exit_status" => ctx.exit_status
    }
  end

  defp send_rate_packets_per_second(measurement) do
    number(measurement["send_rate_packets_per_second"]) ||
      number(measurement["send_rate_datagrams_per_second"])
  end

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
    stream_failure? = stream_failure?(ctx)

    %{
      "first_break_symptom" =>
        first_symptom(
          ctx.timed_out?,
          failed?,
          invalid_measurement?,
          datagram_loss?,
          stream_failure?
        ),
      "stopped_by" =>
        stopped_by(ctx.timed_out?, failed?, invalid_measurement?, datagram_loss?, stream_failure?),
      "connection_closed" => false,
      "protocol_error" => failed? || invalid_measurement? || stream_failure?,
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
    message =
      cond do
        ctx.timed_out? ->
          "reference comparison step timed out after #{seconds(ctx.timeout_ms)}s"

        stream_failure?(ctx) ->
          stream_failure_message(measurement(ctx)["stream_failure"])

        ctx.exit_status != 0 ->
          failure_output(ctx.step_output) ||
            "reference comparison step exited with status #{ctx.exit_status}"

        offered_rate_invalid?(ctx.config, ctx.measurement) ->
          "reference comparison offered rate below tolerance: actual/target #{number(measurement(ctx)["offered_rate_ratio"])} < #{ctx.config.offered_rate_tolerance}"

        !valid_measurement?(ctx.config, ctx.measurement) ->
          "reference comparison step did not produce a valid client_run measurement"

        true ->
          nil
      end

    %{
      "close_reason" => if(ctx.timed_out?, do: "timeout", else: nil),
      "error_code" => ctx.exit_status,
      "message" => message,
      "details" => measurement(ctx)["stream_failure"]
    }
  end

  defp stream_failure?(ctx), do: is_map(measurement(ctx)["stream_failure"])

  defp stream_failure_message(nil), do: nil

  defp stream_failure_message(failure) do
    "moqx bidirectional stream failed during #{failure["phase"]}: " <>
      "reason=#{failure["reason"]} stream=#{failure["stream_index"]} " <>
      "received=#{failure["bytes_received"]}/#{failure["bytes_expected"]}"
  end

  defp first_symptom(true, _failed?, _invalid_json?, _datagram_loss?, _stream_failure?),
    do: "step_timeout"

  defp first_symptom(false, true, _invalid_json?, _datagram_loss?, _stream_failure?),
    do: "protocol_error"

  defp first_symptom(false, false, true, _datagram_loss?, _stream_failure?),
    do: "tool_output_invalid"

  defp first_symptom(false, false, false, true, _stream_failure?),
    do: "datagram_delivery_loss"

  defp first_symptom(false, false, false, false, true),
    do: "stream_closed_before_expected_bytes"

  defp first_symptom(false, false, false, false, false), do: nil

  defp stopped_by(true, _failed?, _invalid_json?, _datagram_loss?, _stream_failure?),
    do: @timeout_stop_condition

  defp stopped_by(false, true, _invalid_json?, _datagram_loss?, _stream_failure?),
    do: "reference_comparison_nonzero_exit"

  defp stopped_by(false, false, true, _datagram_loss?, _stream_failure?),
    do: "reference_comparison_invalid_measurement"

  defp stopped_by(false, false, false, true, _stream_failure?), do: "datagram_delivery_loss"

  defp stopped_by(false, false, false, false, true),
    do: "stream_closed_before_expected_bytes"

  defp stopped_by(false, false, false, false, false), do: nil

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
      --workload VALUE               stream_pressure or datagram_pressure (default: stream_pressure)
      --stream-direction VALUE       bidirectional or unidirectional (default: bidirectional)
      --stream-count N               concurrent streams (default: 1)
      --payload-size BYTES           bytes per payload write (default: 1200)
      --payload-count N              payload writes per stream (default: 1)
      --datagram-size BYTES          bytes per datagram for datagram_pressure (default: 1200)
      --datagram-count N             datagrams to send for datagram_pressure (default: 1000)
      --datagram-rate N              target datagrams/sec for paced datagram_pressure
      --duration-seconds N           paced datagram_pressure duration; offered = rate * duration
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
