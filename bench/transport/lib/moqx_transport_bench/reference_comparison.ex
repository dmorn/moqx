defmodule MOQX.TransportBench.ReferenceComparison do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.TransportBench.BuildInfo
  alias MOQX.TransportBench.PathMetadata

  @default_script "moqx-transport-bench reference-comparison"
  @script_version "v1"
  @schema_version "transport-bench-v1"
  @timeout_exit_status 124
  @timeout_stop_condition "reference_comparison_step_timeout"
  @reference_client_topology "reference-client-to-reference-server"
  @moqx_client_topology "moqx-client-to-reference-server"
  @supported_topologies [@reference_client_topology, @moqx_client_topology]

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
          topology: :string,
          server: :string,
          port: :integer,
          ca: :string,
          servername: :string,
          alpn: :string,
          stream_direction: :string,
          stream_count: :integer,
          payload_size: :integer,
          payload_count: :integer,
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
        build_config(opts, argv, script)
    end
  end

  defp build_config(opts, argv, script) do
    config = %{
      argv: argv,
      script: script,
      command: command_string(script, argv),
      topology: opts[:topology],
      server: opts[:server],
      port: Keyword.get(opts, :port, 4433),
      ca: opts[:ca],
      servername: opts[:servername],
      alpn: Keyword.get(opts, :alpn, "moqx-test"),
      stream_direction: Keyword.get(opts, :stream_direction, "bidirectional"),
      stream_count: Keyword.get(opts, :stream_count, 1),
      payload_size: Keyword.get(opts, :payload_size, 1200),
      payload_count: Keyword.get(opts, :payload_count, 1),
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
         :ok <- validate_positive(config.stream_count, "--stream-count"),
         :ok <- validate_positive(config.payload_size, "--payload-size"),
         :ok <- validate_positive(config.payload_count, "--payload-count"),
         :ok <- validate_positive(config.timeout_seconds, "--timeout-seconds"),
         :ok <- validate_positive(config.timeout_margin_seconds, "--timeout-margin-seconds"),
         :ok <- validate_stream_direction(config.stream_direction) do
      {:ok, config}
    end
  end

  defp validate_positive(value, _name) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(_value, name), do: {:error, "#{name} must be greater than 0."}

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
  defp run_topology(%{topology: @moqx_client_topology} = config), do: run_moqx_client(config)

  defp run_quicprobe(config) do
    args = quicprobe_args(config)
    timeout_ms = (config.timeout_seconds + config.timeout_margin_seconds) * 1000
    {output, status, timed_out?} = run_command(config.quicprobe_command, args, timeout_ms)
    measurement = decode_json(output)

    {measurement, output, status, [config.quicprobe_command | args], timed_out?, timeout_ms}
  end

  defp quicprobe_args(config) do
    args = [
      "client",
      "--addr",
      "#{config.server}:#{config.port}",
      "--ca",
      config.ca,
      "--alpn",
      config.alpn,
      "--json",
      "--stream-direction",
      config.stream_direction,
      "--stream-count",
      Integer.to_string(config.stream_count),
      "--payload-size",
      Integer.to_string(config.payload_size),
      "--payload-count",
      Integer.to_string(config.payload_count),
      "--timeout",
      "#{config.timeout_seconds}s"
    ]

    if config.servername do
      args ++ ["--servername", config.servername]
    else
      args
    end
  end

  defp run_moqx_client(config) do
    args = moqx_client_step_args(config)
    timeout_ms = (config.timeout_seconds + config.timeout_margin_seconds) * 1000

    task =
      Task.async(fn ->
        do_run_moqx_client(config)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, measurement}} ->
        {measurement, "", 0, args, false, timeout_ms}

      {:ok, {:error, message}} ->
        {%{}, message, 1, args, false, timeout_ms}

      nil ->
        {%{}, "", @timeout_exit_status, args, true, timeout_ms}
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
      "--stream-direction",
      config.stream_direction,
      "--stream-count",
      Integer.to_string(config.stream_count),
      "--payload-size",
      Integer.to_string(config.payload_size),
      "--payload-count",
      Integer.to_string(config.payload_count),
      "--timeout",
      "#{config.timeout_seconds}s"
    ]
    |> maybe_append_servername(config.servername)
  end

  defp do_run_moqx_client(config) do
    {:ok, ctx} = Transport.new(MOQX.Transport.Quicer)
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

        try do
          {:ok, measure_moqx_stream_pressure(ctx, connection, config, handshake_latency_ms)}
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

  defp connect_opts(config) do
    [
      alpn: config.alpn,
      cacertfile: config.ca,
      verify: :verify_peer,
      peer_bidi_stream_count: max(config.stream_count + 2, 10),
      peer_unidi_stream_count: max(config.stream_count + 2, 10)
    ]
    |> maybe_put_server_name(config.servername)
  end

  defp maybe_put_server_name(opts, nil), do: opts
  defp maybe_put_server_name(opts, servername), do: Keyword.put(opts, :server_name, servername)

  defp client_timeout_ms(config), do: config.timeout_seconds * 1000

  defp measure_moqx_stream_pressure(ctx, connection, config, handshake_latency_ms) do
    application_started_at = monotonic_us()
    payload = binary_payload(config.payload_size)

    {result, _ctx} =
      Enum.reduce(1..config.stream_count, {empty_stream_result(), ctx}, fn _index,
                                                                           {result, ctx} ->
        {stream_result, ctx} =
          run_moqx_pressure_stream(ctx, connection, payload, config, application_started_at)

        {merge_stream_result(result, stream_result), ctx}
      end)

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
      "stream_scheduling" => "sequential"
    }
  end

  defp empty_stream_result do
    %{
      bytes_sent: 0,
      bytes_received: 0,
      first_byte_latency_ms: nil,
      stream_latencies_ms: []
    }
  end

  defp run_moqx_pressure_stream(ctx, connection, payload, config, first_byte_origin) do
    stream_started_at = monotonic_us()

    {:ok, stream, ctx} =
      Transport.open_stream(ctx, connection, direction: stream_direction(config))

    {sent, ctx} = send_payloads(ctx, stream, payload, config.payload_count)
    {:ok, ctx} = Transport.finish_sending(ctx, stream)

    {received, first_byte_latency_ms, ctx} =
      if config.stream_direction == "bidirectional" do
        recv_echo_payload(ctx, stream, payload, config.payload_count, first_byte_origin)
      else
        {0, nil, ctx}
      end

    {%{
       bytes_sent: sent,
       bytes_received: received,
       first_byte_latency_ms: first_byte_latency_ms,
       stream_latencies_ms: [elapsed_ms(stream_started_at)]
     }, ctx}
  end

  defp stream_direction(%{stream_direction: "bidirectional"}), do: :bidirectional
  defp stream_direction(%{stream_direction: "unidirectional"}), do: :unidirectional

  defp send_payloads(ctx, stream, payload, count) do
    Enum.reduce(1..count, {0, ctx}, fn _index, {bytes, ctx} ->
      {:ok, _send, ctx} = Transport.send_stream(ctx, stream, payload, [])
      {bytes + byte_size(payload), ctx}
    end)
  end

  defp recv_echo_payload(ctx, stream, payload, count, first_byte_origin) do
    expected_bytes = byte_size(payload) * count
    recv_echo_payload(ctx, stream, payload, expected_bytes, 0, nil, first_byte_origin)
  end

  defp recv_echo_payload(
         ctx,
         _stream,
         _payload,
         expected_bytes,
         expected_bytes,
         first_byte_latency_ms,
         _first_byte_origin
       ) do
    {expected_bytes, first_byte_latency_ms, ctx}
  end

  defp recv_echo_payload(
         ctx,
         stream,
         payload,
         expected_bytes,
         received,
         first_byte_latency_ms,
         first_byte_origin
       ) do
    remaining = expected_bytes - received
    {:ok, data, ctx} = Transport.recv_stream(ctx, stream, remaining)

    unless matches_payload?(data, payload, received) do
      raise "echo payload mismatch"
    end

    first_byte_latency_ms = first_byte_latency_ms || elapsed_ms(first_byte_origin)

    recv_echo_payload(
      ctx,
      stream,
      payload,
      expected_bytes,
      received + byte_size(data),
      first_byte_latency_ms,
      first_byte_origin
    )
  end

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
      stream_latencies_ms: left.stream_latencies_ms ++ right.stream_latencies_ms
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
      "errors" => errors(ctx)
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
      "datagrams" => false,
      "congestion_control" => nil,
      "pacing" => nil,
      "settings" => %{
        "topology" => ctx.config.topology,
        "reference_tool" => "quicprobe",
        "measurement_schema" => measurement["schema_version"],
        "client_implementation" => measurement["client_implementation"] || "quicprobe",
        "stream_scheduling" =>
          measurement["stream_scheduling"] || default_stream_scheduling(ctx.config)
      }
    }
  end

  defp default_stream_scheduling(%{topology: @reference_client_topology}), do: "concurrent"
  defp default_stream_scheduling(%{topology: @moqx_client_topology}), do: "sequential"

  defp workload_metadata(ctx) do
    measurement = measurement(ctx)
    duration_seconds = seconds(measurement["application_duration_ms"])
    stream_count = measurement["stream_count"] || ctx.config.stream_count
    payload_count = measurement["payload_count"] || ctx.config.payload_count

    %{
      "family" => "reference_comparison",
      "direction" => "client_to_server",
      "stream_direction" => measurement["stream_direction"] || ctx.config.stream_direction,
      "stream_count" => stream_count,
      "payload_size_bytes" => measurement["payload_size_bytes"] || ctx.config.payload_size,
      "payloads_per_second" => rate(stream_count * payload_count, duration_seconds),
      "offered_load_bps" => nil,
      "datagram_size_bytes" => nil,
      "datagrams_per_second" => nil,
      "control_trickle_bps" => nil,
      "topology" => ctx.config.topology,
      "tool" => workload_tool(ctx.config),
      "server" => ctx.config.server,
      "port" => ctx.config.port
    }
  end

  defp workload_tool(%{topology: @moqx_client_topology}), do: "moqx"
  defp workload_tool(_config), do: "quicprobe"

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
    latencies = measurement["stream_latency_ms"] || %{}

    %{
      "handshake_latency_ms" => number(measurement["handshake_latency_ms"]),
      "first_byte_latency_ms" => number(measurement["first_byte_latency_ms"]),
      "offered_load_bps" => nil,
      "goodput_bps" => number(measurement["goodput_bps"]),
      "send_rate_packets_per_second" => number(measurement["send_rate_packets_per_second"]),
      "send_rate_datagrams_per_second" => nil,
      "delivered_datagrams_per_second" => nil,
      "datagram_delivery_ratio" => nil,
      "datagram_drop_count" => nil,
      "datagram_late_count" => nil,
      "stream_count" => number(measurement["stream_count"]) || ctx.config.stream_count,
      "payload_size_bytes" =>
        number(measurement["payload_size_bytes"]) || ctx.config.payload_size,
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
      "stream_stall_count" => if(ctx.exit_status == 0, do: 0, else: nil),
      "control_latency_p99_ms" => nil,
      "bytes_sent" => number(measurement["bytes_sent"]),
      "bytes_received" => number(measurement["bytes_received"]),
      "reference_comparison_exit_status" => ctx.exit_status
    }
  end

  defp limits(ctx) do
    failed? = ctx.exit_status != 0 && !ctx.timed_out?

    invalid_measurement? =
      ctx.exit_status == 0 && !valid_measurement?(ctx.config, ctx.measurement)

    %{
      "first_break_symptom" => first_symptom(ctx.timed_out?, failed?, invalid_measurement?),
      "stopped_by" => stopped_by(ctx.timed_out?, failed?, invalid_measurement?),
      "connection_closed" => false,
      "protocol_error" => failed? || invalid_measurement?,
      "throughput_plateau" => false,
      "latency_explosion" => false,
      "mailbox_growth_without_recovery" => false,
      "cpu_saturation" => false,
      "memory_saturation" => false,
      "control_traffic_delayed" => false
    }
  end

  defp errors(ctx) do
    message =
      cond do
        ctx.timed_out? ->
          "reference comparison step timed out after #{seconds(ctx.timeout_ms)}s"

        ctx.exit_status != 0 ->
          failure_output(ctx.step_output) ||
            "reference comparison step exited with status #{ctx.exit_status}"

        !valid_measurement?(ctx.config, ctx.measurement) ->
          "reference comparison step did not produce a valid client_run measurement"

        true ->
          nil
      end

    %{
      "close_reason" => if(ctx.timed_out?, do: "timeout", else: nil),
      "error_code" => ctx.exit_status,
      "message" => message
    }
  end

  defp first_symptom(true, _failed?, _invalid_json?), do: "step_timeout"
  defp first_symptom(false, true, _invalid_json?), do: "protocol_error"
  defp first_symptom(false, false, true), do: "tool_output_invalid"
  defp first_symptom(false, false, false), do: nil

  defp stopped_by(true, _failed?, _invalid_json?), do: @timeout_stop_condition
  defp stopped_by(false, true, _invalid_json?), do: "reference_comparison_nonzero_exit"
  defp stopped_by(false, false, true), do: "reference_comparison_invalid_measurement"
  defp stopped_by(false, false, false), do: nil

  defp measurement(%{measurement: measurement}) when is_map(measurement), do: measurement
  defp measurement(_ctx), do: %{}

  defp valid_measurement?(
         %{topology: @reference_client_topology},
         %{"schema_version" => "quicprobe-v1", "record_type" => "client_run"}
       ),
       do: true

  defp valid_measurement?(
         %{topology: @moqx_client_topology},
         %{"schema_version" => "moqx-reference-measurement-v1", "record_type" => "client_run"}
       ),
       do: true

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

  defp rate(_count, nil), do: nil
  defp rate(_count, seconds) when not is_number(seconds) or seconds <= 0, do: nil
  defp rate(count, seconds), do: count / seconds

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
      --topology VALUE               reference-client-to-reference-server or moqx-client-to-reference-server
      --server HOST                  reference server host or IP
      --ca PATH                      CA certificate for the reference server

    Common options:
      --port PORT                    reference server UDP port (default: 4433)
      --alpn VALUE                   QUIC ALPN (default: moqx-test)
      --servername VALUE             TLS server name override
      --stream-direction VALUE       bidirectional or unidirectional (default: bidirectional)
      --stream-count N               concurrent streams (default: 1)
      --payload-size BYTES           bytes per payload write (default: 1200)
      --payload-count N              payload writes per stream (default: 1)
      --timeout-seconds N            client timeout (default: 5)
      --timeout-margin-seconds N     kill/abort step after timeout + N seconds (default: 2)
      --quicprobe-command PATH       quicprobe executable for reference-client topology (default: quicprobe)
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
    """
  end
end
