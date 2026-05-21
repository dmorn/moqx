defmodule MOQX.TransportBench.QuicerSelfPair do
  @moduledoc false

  alias MOQX.TransportBench.BuildInfo

  alias MOQX.Transport
  alias MOQX.Transport.Profile

  @default_script "moqx-transport-bench self-pair"
  @script_version "v1"
  @schema_version "transport-bench-v1"
  @default_cert_dir ".tmp/transport-bench-certs"

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
    argv = strip_mix_separator(argv)

    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          profile: :string,
          host: :string,
          stream_count: :integer,
          stream_direction: :string,
          payload_size: :integer,
          payload_count: :integer,
          datagram_size: :integer,
          datagram_count: :integer,
          timeout_ms: :integer,
          cert_dir: :string,
          certfile: :string,
          keyfile: :string,
          cacertfile: :string,
          run_id: :string,
          output: :string,
          notes: :string,
          help: :boolean
        ],
        aliases: [
          p: :profile,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        {:help, usage(script)}

      invalid != [] ->
        {:error, "Invalid options: #{inspect(invalid)}\n\n#{usage(script)}"}

      args != [] ->
        {:error, "Unexpected arguments: #{Enum.join(args, " ")}\n\n#{usage(script)}"}

      true ->
        build_config(opts, argv, script)
    end
  end

  defp strip_mix_separator(["--" | argv]), do: argv
  defp strip_mix_separator(argv), do: argv

  defp build_config(opts, argv, script) do
    with {:ok, profile_name} <- parse_profile(Keyword.get(opts, :profile, "draft_14")),
         {:ok, profile} <- Profile.fetch(profile_name),
         {:ok, stream_direction} <-
           parse_stream_direction(Keyword.get(opts, :stream_direction, "auto")),
         {:ok, certs} <- cert_config(opts),
         {:ok, payload_size} <- positive_integer(opts, :payload_size, 1200),
         {:ok, payload_count} <- positive_integer(opts, :payload_count, 100),
         {:ok, stream_count} <-
           positive_integer(opts, :stream_count, default_stream_count(profile)),
         {:ok, datagram_size} <- positive_integer(opts, :datagram_size, 1200),
         {:ok, datagram_count} <- non_negative_integer(opts, :datagram_count, 1000),
         {:ok, timeout_ms} <- positive_integer(opts, :timeout_ms, 5_000),
         :ok <- validate_datagram_size(profile, datagram_size) do
      {:ok,
       %{
         argv: argv,
         script: script,
         command: command_string(script, argv),
         profile: profile,
         host: Keyword.get(opts, :host, "127.0.0.1"),
         stream_count: stream_count,
         stream_direction: resolve_stream_direction(profile, stream_direction),
         payload_size: payload_size,
         payload_count: payload_count,
         datagram_size: datagram_size,
         datagram_count: datagram_count,
         timeout_ms: timeout_ms,
         certs: certs,
         run_id: opts[:run_id] || default_run_id(profile),
         output: opts[:output],
         notes: opts[:notes]
       }}
    end
  end

  defp parse_profile("draft_14"), do: {:ok, :draft_14}
  defp parse_profile("moq_lite_04"), do: {:ok, :moq_lite_04}
  defp parse_profile(profile), do: {:error, "Unknown --profile #{inspect(profile)}."}

  defp parse_stream_direction("auto"), do: {:ok, :auto}
  defp parse_stream_direction("bidirectional"), do: {:ok, :bidirectional}
  defp parse_stream_direction("unidirectional"), do: {:ok, :unidirectional}

  defp parse_stream_direction(direction) do
    {:error,
     "Unknown --stream-direction #{inspect(direction)}. Expected auto, bidirectional, or unidirectional."}
  end

  defp cert_config(opts) do
    explicit = [opts[:certfile], opts[:keyfile], opts[:cacertfile]]

    cond do
      Enum.all?(explicit, &is_binary/1) ->
        {:ok,
         %{
           cert_dir: nil,
           certfile: opts[:certfile],
           keyfile: opts[:keyfile],
           cacertfile: opts[:cacertfile]
         }}

      Enum.any?(explicit, &is_binary/1) ->
        {:error, "Pass --certfile, --keyfile, and --cacertfile together, or omit all three."}

      true ->
        cert_dir = Keyword.get(opts, :cert_dir, @default_cert_dir)

        {:ok,
         %{
           cert_dir: cert_dir,
           certfile: Path.join(cert_dir, "server.pem"),
           keyfile: Path.join(cert_dir, "server-key.pem"),
           cacertfile: Path.join(cert_dir, "ca.pem")
         }}
    end
  end

  defp positive_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) && value > 0 do
      {:ok, value}
    else
      {:error, "--#{option_name(key)} must be a positive integer."}
    end
  end

  defp non_negative_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) && value >= 0 do
      {:ok, value}
    else
      {:error, "--#{option_name(key)} must be a non-negative integer."}
    end
  end

  defp option_name(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp default_stream_count(%{name: :draft_14}), do: 1
  defp default_stream_count(%{name: :moq_lite_04}), do: 8

  defp resolve_stream_direction(%{name: :draft_14}, :auto), do: :unidirectional
  defp resolve_stream_direction(%{name: :moq_lite_04}, :auto), do: :bidirectional
  defp resolve_stream_direction(_profile, direction), do: direction

  defp validate_datagram_size(%{capabilities: %{datagrams: true}}, size) when size >= 8, do: :ok

  defp validate_datagram_size(%{capabilities: %{datagrams: true}}, _size),
    do: {:error, "--datagram-size must be at least 8 bytes."}

  defp validate_datagram_size(_profile, _size), do: :ok

  defp run(config) do
    with :ok <- ensure_certs(config.certs),
         {:ok, _apps} <- Application.ensure_all_started(:quicer),
         {:ok, records} <- with_pair(config, &run_steps/2) do
      write_records(records, config.output)
    else
      {:error, message} when is_binary(message) ->
        IO.puts(:stderr, message)
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, inspect(reason))
        System.halt(1)
    end
  end

  defp with_pair(config, fun) do
    {:ok, ctx} = Transport.new(MOQX.Transport.Quicer)

    with {:ok, listener, ctx} <- start_listener(ctx, config),
         {:ok, {_ip, port}} <- Transport.local_address(ctx, listener),
         pair_started_at = monotonic_us(),
         {:ok, ctx, client, server} <- connect_pair(ctx, listener, port, config) do
      pair = %{
        ctx: flush_transport_events(ctx),
        listener: listener,
        client: client,
        server: server,
        handshake_latency_ms: elapsed_ms(pair_started_at)
      }

      try do
        fun.(pair, config)
      after
        cleanup(pair)
      end
    else
      {:error, reason, _ctx} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_listener(ctx, config) do
    Transport.listen(
      ctx,
      "#{config.host}:0",
      datagram_opts(config.profile) ++
        [
          alpn: config.profile.alpn,
          certfile: config.certs.certfile,
          keyfile: config.certs.keyfile,
          peer_bidi_stream_count: max(config.stream_count + 2, 10),
          peer_unidi_stream_count: max(config.stream_count + 2, 10)
        ]
    )
  end

  defp connect_pair(ctx, listener, port, config) do
    owner = self()
    accept_ctx = drop_listeners(ctx)
    accept_task = Task.async(fn -> accept_server(accept_ctx, listener, owner, config) end)

    case connect_client(ctx, port, config) do
      {:ok, client, ctx} -> await_server_for_client(ctx, client, accept_task)
      {:error, reason, _ctx} -> stop_accept_task(accept_task, reason)
    end
  end

  defp accept_server(ctx, listener, owner, config) do
    with {:ok, server, ctx} <- Transport.accept(ctx, listener, [], config.timeout_ms),
         {:ok, server, ctx} <- Transport.handshake(ctx, server, config.timeout_ms),
         {:ok, ctx} <- Transport.controlling_process(ctx, owner) do
      {:ok, server, ctx}
    end
  end

  defp connect_client(ctx, port, config) do
    Transport.connect(ctx, config.host, port, connect_opts(config), config.timeout_ms)
  end

  defp connect_opts(config) do
    datagram_opts(config.profile) ++
      [
        alpn: config.profile.alpn,
        cacertfile: config.certs.cacertfile,
        verify: :verify_peer,
        server_name: "localhost",
        peer_bidi_stream_count: max(config.stream_count + 2, 10),
        peer_unidi_stream_count: max(config.stream_count + 2, 10)
      ]
  end

  defp await_server_for_client(ctx, client, accept_task) do
    case await_accept_server(accept_task) do
      {:ok, server, accept_ctx} -> {:ok, merge_contexts(ctx, accept_ctx), client, server}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_accept_server(task) do
    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :accept_timeout}
    end
  end

  defp stop_accept_task(accept_task, reason) do
    Task.shutdown(accept_task, :brutal_kill)
    {:error, reason}
  end

  defp drop_listeners(ctx), do: update_in(ctx.backend.data.listeners, fn _listeners -> %{} end)

  defp merge_contexts(ctx, accepted_ctx) do
    update_in(ctx.backend.data, fn data ->
      data
      |> Map.update!(:listeners, &Map.merge(&1, accepted_ctx.backend.data.listeners))
      |> Map.update!(:connections, &Map.merge(&1, accepted_ctx.backend.data.connections))
      |> Map.update!(:streams, &Map.merge(&1, accepted_ctx.backend.data.streams))
    end)
  end

  defp cleanup(pair) do
    _client_result = Transport.close_connection(pair.ctx, pair.client, 0)
    _server_result = Transport.close_connection(pair.ctx, pair.server, 0)
    _listener_result = Transport.close_listener(pair.ctx, pair.listener, 0)
    :ok
  end

  defp datagram_opts(%{capabilities: %{datagrams: true}}), do: [datagram_receive_enabled: 1]
  defp datagram_opts(_profile), do: []

  defp run_steps(pair, config) do
    started_at = timestamp()
    steps = steps(config)

    {records, _pair, _stopped?} =
      steps
      |> Enum.with_index(1)
      |> Enum.reduce({[], pair, false}, fn
        {_step, _index}, {records, pair, true} ->
          {records, pair, true}

        {step, index}, {records, pair, false} ->
          {record, pair, failed?} = run_step(pair, config, step, index, length(steps), started_at)
          {records ++ [record], pair, failed?}
      end)

    {:ok, records}
  end

  defp steps(config) do
    base = [
      %{name: "handshake_first_byte", family: "self_pair_calibration"},
      %{name: "stream_pressure", family: "self_pair_calibration"}
    ]

    if config.profile.capabilities.datagrams == true && config.datagram_count > 0 do
      base ++ [%{name: "datagram_pressure", family: "self_pair_calibration"}]
    else
      base
    end
  end

  defp run_step(pair, config, step, index, step_count, run_started_at) do
    step_started_at = timestamp()

    try do
      {measurement, pair} = measure_step(step.name, pair, config)
      step_finished_at = timestamp()

      record =
        build_record(%{
          config: config,
          step: step,
          step_index: index,
          step_count: step_count,
          run_started_at: run_started_at,
          step_started_at: step_started_at,
          step_finished_at: step_finished_at,
          measurement: measurement,
          error: nil
        })

      {record, pair, false}
    rescue
      exception ->
        {error, stacktrace} = {exception, __STACKTRACE__}
        step_finished_at = timestamp()

        record =
          build_record(%{
            config: config,
            step: step,
            step_index: index,
            step_count: step_count,
            run_started_at: run_started_at,
            step_started_at: step_started_at,
            step_finished_at: step_finished_at,
            measurement: %{},
            error: Exception.format(:error, error, stacktrace)
          })

        {record, pair, true}
    end
  end

  defp measure_step("handshake_first_byte", pair, config) do
    started_at = monotonic_us()

    {client_stream, server_stream, ctx} =
      open_stream_pair(pair.ctx, pair.client, pair.server, config)

    {:ok, _send, ctx} = Transport.send_stream(ctx, client_stream, <<1>>, [])
    {:ok, <<1>>, ctx} = Transport.recv_stream(ctx, server_stream, 1)
    first_byte_latency_ms = elapsed_ms(started_at)

    measurement = %{
      "handshake_latency_ms" => pair.handshake_latency_ms,
      "first_byte_latency_ms" => first_byte_latency_ms,
      "stream_count" => 1,
      "payload_size_bytes" => 1
    }

    {%{"duration_ms" => first_byte_latency_ms, "metrics" => measurement},
     %{pair | ctx: flush_transport_events(ctx)}}
  end

  defp measure_step("stream_pressure", pair, config) do
    {streams, ctx} =
      Enum.map_reduce(1..config.stream_count, pair.ctx, fn _index, ctx ->
        {client_stream, server_stream, ctx} =
          open_stream_pair(ctx, pair.client, pair.server, config)

        {{client_stream, server_stream}, ctx}
      end)

    payload = binary_payload(config.payload_size)
    started_at = monotonic_us()

    {bytes_received, ctx} =
      Enum.reduce(streams, {0, ctx}, fn {client_stream, server_stream}, {bytes, ctx} ->
        {stream_bytes, ctx} = stream_payloads(ctx, client_stream, server_stream, payload, config)
        {bytes + stream_bytes, ctx}
      end)

    duration_ms = elapsed_ms(started_at)
    payloads = config.stream_count * config.payload_count

    measurement = %{
      "duration_ms" => duration_ms,
      "metrics" => %{
        "goodput_bps" => bits_per_second(bytes_received, duration_ms),
        "send_rate_packets_per_second" => rate(payloads, duration_ms),
        "stream_count" => config.stream_count,
        "payload_size_bytes" => config.payload_size,
        "offered_load_bps" => nil,
        "stream_stall_count" => 0
      }
    }

    {measurement, %{pair | ctx: flush_transport_events(ctx)}}
  end

  defp measure_step("datagram_pressure", pair, config) do
    ctx = flush_transport_events(pair.ctx)
    started_at = monotonic_us()

    ctx =
      Enum.reduce(1..config.datagram_count, ctx, fn sequence, ctx ->
        {:ok, ctx} = Transport.send_datagram(ctx, pair.client, datagram_payload(sequence, config))
        ctx
      end)

    send_duration_ms = elapsed_ms(started_at)
    {received, ctx} = receive_datagrams(ctx, pair.server, config, MapSet.new(), monotonic_us())
    duration_ms = elapsed_ms(started_at)
    received_count = MapSet.size(received)
    dropped_count = config.datagram_count - received_count

    measurement = %{
      "duration_ms" => duration_ms,
      "metrics" => %{
        "goodput_bps" => bits_per_second(received_count * config.datagram_size, duration_ms),
        "send_rate_packets_per_second" => rate(config.datagram_count, send_duration_ms),
        "send_rate_datagrams_per_second" => rate(config.datagram_count, send_duration_ms),
        "delivered_datagrams_per_second" => rate(received_count, duration_ms),
        "datagram_delivery_ratio" => ratio(received_count, config.datagram_count),
        "datagram_drop_count" => dropped_count,
        "datagram_late_count" => nil,
        "payload_size_bytes" => config.datagram_size,
        "stream_count" => nil
      },
      "limits" => %{
        "first_break_symptom" => if(dropped_count > 0, do: "datagram_delivery_loss", else: nil)
      }
    }

    {measurement, %{pair | ctx: flush_transport_events(ctx)}}
  end

  defp open_stream_pair(ctx, client, server, config) do
    {:ok, client_stream, ctx} =
      Transport.open_stream(ctx, client, direction: config.stream_direction)

    {:ok, server_stream, ctx} = Transport.accept_stream(ctx, server, [], config.timeout_ms)
    {client_stream, server_stream, ctx}
  end

  defp stream_payloads(ctx, client_stream, server_stream, payload, config) do
    Enum.reduce(1..config.payload_count, {0, ctx}, fn _index, {bytes, ctx} ->
      {:ok, _send, ctx} = Transport.send_stream(ctx, client_stream, payload, [])
      {:ok, received, ctx} = recv_exact(ctx, server_stream, byte_size(payload), <<>>)
      {bytes + byte_size(received), ctx}
    end)
  end

  defp recv_exact(ctx, _stream, byte_count, acc) when byte_size(acc) == byte_count do
    {:ok, acc, ctx}
  end

  defp recv_exact(ctx, stream, byte_count, acc) do
    remaining = byte_count - byte_size(acc)
    {:ok, data, ctx} = Transport.recv_stream(ctx, stream, remaining)
    recv_exact(ctx, stream, byte_count, acc <> data)
  end

  defp receive_datagrams(ctx, server, config, received, started_at) do
    if MapSet.size(received) >= config.datagram_count or
         elapsed_ms(started_at) >= config.timeout_ms do
      {received, ctx}
    else
      remaining_ms = max(config.timeout_ms - trunc(elapsed_ms(started_at)), 0)

      case Transport.receive_event(ctx, remaining_ms) do
        {:ok, {:datagram, ^server, payload, _metadata}, ctx} ->
          received = maybe_record_datagram(received, payload)
          receive_datagrams(ctx, server, config, received, started_at)

        {:ok, _event, ctx} ->
          receive_datagrams(ctx, server, config, received, started_at)

        {:unknown, _message, ctx} ->
          receive_datagrams(ctx, server, config, received, started_at)

        {:error, _reason, ctx} ->
          receive_datagrams(ctx, server, config, received, started_at)

        {:timeout, ctx} ->
          {received, ctx}
      end
    end
  end

  defp maybe_record_datagram(received, <<sequence::unsigned-big-64, _rest::binary>>) do
    MapSet.put(received, sequence)
  end

  defp maybe_record_datagram(received, _payload), do: received

  defp flush_transport_events(ctx) do
    case Transport.receive_event(ctx, 0) do
      {:timeout, ctx} -> ctx
      {:ok, _event, ctx} -> flush_transport_events(ctx)
      {:unknown, _message, ctx} -> flush_transport_events(ctx)
      {:error, _reason, ctx} -> flush_transport_events(ctx)
    end
  end

  defp build_record(ctx) do
    %{
      "schema_version" => @schema_version,
      "record_type" => "step_summary",
      "run" => run_metadata(ctx),
      "path" => path_metadata(ctx.config),
      "software" => software_metadata(),
      "profile" => profile_metadata(ctx.config.profile),
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
      "step_command" => step_command(ctx)
    }
  end

  defp step_command(ctx), do: "#{ctx.config.command} # step=#{ctx.step.name}"

  defp path_metadata(config) do
    %{
      "evidence_tier" => "loopback_calibration",
      "path_id" => "loopback-#{config.host}-quicer-self-pair",
      "client" => local_endpoint("client", config),
      "server" => local_endpoint("server", config)
    }
  end

  defp local_endpoint(role, config) do
    %{
      "host_id" => "#{hostname()}-#{role}",
      "provider" => "local",
      "region" => nil,
      "instance_class" => nil,
      "os" => os_description(),
      "kernel" => kernel(),
      "cpu_model" => cpu_model(),
      "memory_bytes" => memory_bytes(),
      "nic_or_network_class" => if(loopback?(config.host), do: "loopback", else: nil)
    }
  end

  defp software_metadata do
    %{
      "elixir_version" => System.version(),
      "otp_version" => System.otp_release(),
      "moqx_version" => moqx_version(),
      "quicer_version" => app_version(:quicer),
      "msquic_version" => nil,
      "reference_implementation" => nil,
      "reference_version" => nil
    }
  end

  defp profile_metadata(profile) do
    %{
      "name" => Atom.to_string(profile.name),
      "alpn" => profile.alpn,
      "datagrams" => profile.capabilities.datagrams,
      "congestion_control" => nil,
      "pacing" => nil,
      "settings" => profile.stream_expectations
    }
  end

  defp workload_metadata(ctx) do
    base = %{
      "family" => ctx.step.family,
      "direction" => "client_to_server",
      "stream_direction" => Atom.to_string(ctx.config.stream_direction),
      "stream_count" => ctx.config.stream_count,
      "payload_size_bytes" => ctx.config.payload_size,
      "payloads_per_second" => nil,
      "offered_load_bps" => metric(ctx, "offered_load_bps"),
      "datagram_size_bytes" => nil,
      "datagrams_per_second" => nil,
      "control_trickle_bps" => nil,
      "step" => ctx.step.name
    }

    case ctx.step.name do
      "datagram_pressure" ->
        %{
          base
          | "stream_direction" => nil,
            "stream_count" => nil,
            "payload_size_bytes" => ctx.config.datagram_size,
            "datagram_size_bytes" => ctx.config.datagram_size,
            "datagrams_per_second" => metric(ctx, "send_rate_datagrams_per_second")
        }

      "handshake_first_byte" ->
        %{base | "stream_count" => 1, "payload_size_bytes" => 1}

      _step ->
        base
    end
  end

  defp methodology_metadata(ctx) do
    %{
      "warmup_seconds" => 0,
      "step_seconds" => seconds(ctx.measurement["duration_ms"]),
      "cooldown_seconds" => 0,
      "step_index" => ctx.step_index,
      "step_count" => ctx.step_count,
      "repetition_index" => 1,
      "repetition_count" => 1,
      "stop_conditions" => ["step_error", "datagram_delivery_loss"]
    }
  end

  defp metrics(ctx) do
    defaults = %{
      "handshake_latency_ms" => nil,
      "first_byte_latency_ms" => nil,
      "offered_load_bps" => nil,
      "goodput_bps" => nil,
      "send_rate_packets_per_second" => nil,
      "send_rate_datagrams_per_second" => nil,
      "delivered_datagrams_per_second" => nil,
      "datagram_delivery_ratio" => nil,
      "datagram_drop_count" => nil,
      "datagram_late_count" => nil,
      "stream_count" => nil,
      "payload_size_bytes" => nil,
      "latency_p50_ms" => nil,
      "latency_p95_ms" => nil,
      "latency_p99_ms" => nil,
      "sender_cpu_percent" => nil,
      "receiver_cpu_percent" => nil,
      "sender_memory_bytes" => nil,
      "receiver_memory_bytes" => nil,
      "sender_mailbox_depth" => mailbox_depth(),
      "receiver_mailbox_depth" => nil,
      "send_backpressure_ms" => nil,
      "stream_stall_count" => 0,
      "control_latency_p99_ms" => nil
    }

    Map.merge(defaults, Map.get(ctx.measurement, "metrics", %{}))
  end

  defp limits(ctx) do
    failed? = is_binary(ctx.error)

    defaults = %{
      "first_break_symptom" => if(failed?, do: "protocol_error", else: nil),
      "stopped_by" => if(failed?, do: "step_error", else: nil),
      "connection_closed" => false,
      "protocol_error" => failed?,
      "throughput_plateau" => false,
      "latency_explosion" => false,
      "mailbox_growth_without_recovery" => false,
      "cpu_saturation" => false,
      "memory_saturation" => false,
      "control_traffic_delayed" => false
    }

    Map.merge(defaults, Map.get(ctx.measurement, "limits", %{}))
  end

  defp errors(ctx) do
    %{
      "close_reason" => nil,
      "error_code" => if(ctx.error, do: 1, else: nil),
      "message" => ctx.error
    }
  end

  defp metric(ctx, key), do: get_in(metrics(ctx), [key])

  defp ensure_certs(%{cert_dir: nil} = certs) do
    missing =
      [certs.certfile, certs.keyfile, certs.cacertfile]
      |> Enum.reject(&File.exists?/1)

    if missing == [] do
      :ok
    else
      {:error, "Missing certificate files: #{Enum.join(missing, ", ")}"}
    end
  end

  defp ensure_certs(certs) do
    if Enum.all?([certs.certfile, certs.keyfile, certs.cacertfile], &File.exists?/1) do
      :ok
    else
      generate_certs(certs)
    end
  end

  defp generate_certs(certs) do
    openssl = System.find_executable("openssl")

    if openssl do
      File.mkdir_p!(certs.cert_dir)
      cnf = Path.join(certs.cert_dir, "openssl.cnf")
      ca_key = Path.join(certs.cert_dir, "ca-key.pem")
      server_csr = Path.join(certs.cert_dir, "server.csr")
      ca_serial = Path.join(certs.cert_dir, "ca.srl")

      File.write!(cnf, openssl_config())

      with :ok <- run_cmd(openssl, ["genrsa", "-out", ca_key, "2048"]),
           :ok <-
             run_cmd(openssl, [
               "req",
               "-x509",
               "-new",
               "-nodes",
               "-key",
               ca_key,
               "-sha256",
               "-days",
               "7",
               "-subj",
               "/CN=moqx transport bench CA",
               "-out",
               certs.cacertfile
             ]),
           :ok <- run_cmd(openssl, ["genrsa", "-out", certs.keyfile, "2048"]),
           :ok <-
             run_cmd(openssl, [
               "req",
               "-new",
               "-key",
               certs.keyfile,
               "-out",
               server_csr,
               "-config",
               cnf
             ]),
           :ok <-
             run_cmd(openssl, [
               "x509",
               "-req",
               "-in",
               server_csr,
               "-CA",
               certs.cacertfile,
               "-CAkey",
               ca_key,
               "-CAcreateserial",
               "-out",
               certs.certfile,
               "-days",
               "7",
               "-sha256",
               "-extensions",
               "v3_req",
               "-extfile",
               cnf
             ]) do
        File.rm(server_csr)
        File.rm(ca_serial)
        :ok
      end
    else
      {:error,
       "openssl not found. Pass --certfile, --keyfile, and --cacertfile, or install openssl."}
    end
  end

  defp run_cmd(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "Command failed with status #{status}: #{String.trim(output)}"}
    end
  end

  defp openssl_config do
    """
    [ req ]
    default_bits = 2048
    distinguished_name = req_distinguished_name
    req_extensions = v3_req
    prompt = no

    [ req_distinguished_name ]
    CN = localhost

    [ v3_req ]
    keyUsage = keyEncipherment, dataEncipherment, digitalSignature
    extendedKeyUsage = serverAuth, clientAuth
    subjectAltName = @alt_names

    [ alt_names ]
    DNS.1 = localhost
    IP.1 = 127.0.0.1
    """
  end

  defp write_records(records, nil) do
    Enum.each(records, fn record ->
      record
      |> encode_json()
      |> IO.iodata_to_binary()
      |> IO.puts()
    end)
  end

  defp write_records(records, path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

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

  defp binary_payload(size), do: :binary.copy(<<0>>, size)

  defp datagram_payload(sequence, config) do
    padding_size = config.datagram_size - 8
    <<sequence::unsigned-big-64, :binary.copy(<<0>>, padding_size)::binary>>
  end

  defp bits_per_second(bytes, duration_ms) when is_number(bytes) and duration_ms > 0 do
    bytes * 8 * 1000 / duration_ms
  end

  defp bits_per_second(_bytes, _duration_ms), do: nil

  defp rate(count, duration_ms) when is_number(count) and duration_ms > 0 do
    count * 1000 / duration_ms
  end

  defp rate(_count, _duration_ms), do: nil

  defp ratio(_count, 0), do: nil
  defp ratio(count, total), do: count / total

  defp seconds(nil), do: nil
  defp seconds(milliseconds), do: milliseconds / 1000

  defp monotonic_us, do: System.monotonic_time(:microsecond)
  defp elapsed_ms(started_at), do: (monotonic_us() - started_at) / 1000
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp default_run_id(profile) do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    "#{timestamp}-loopback-quicer-#{profile.name}"
  end

  defp command_string(script, argv), do: Enum.join([script | argv], " ")

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      version -> List.to_string(version)
    end
  end

  defp moqx_version, do: app_version(:moqx)

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      {:error, _reason} -> nil
    end
  end

  defp os_description do
    case :os.type() do
      {:unix, name} -> Atom.to_string(name)
      other -> inspect(other)
    end
  end

  defp kernel do
    case System.cmd("uname", ["-r"], stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      _error -> nil
    end
  end

  defp cpu_model do
    if File.exists?("/proc/cpuinfo") do
      linux_cpu_model()
    else
      case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
        {value, 0} -> String.trim(value)
        _error -> nil
      end
    end
  end

  defp linux_cpu_model do
    "/proc/cpuinfo"
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] when key in ["model name", "Hardware"] -> String.trim(value)
        _other -> nil
      end
    end)
  end

  defp memory_bytes do
    if File.exists?("/proc/meminfo") do
      linux_memory_bytes()
    else
      case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
        {value, 0} -> value |> String.trim() |> String.to_integer()
        _error -> nil
      end
    end
  rescue
    _error -> nil
  end

  defp linux_memory_bytes do
    "/proc/meminfo"
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^MemTotal:\s+([0-9]+)\s+kB$/, line) do
        [_, value] -> String.to_integer(value) * 1024
        _other -> nil
      end
    end)
  end

  defp mailbox_depth do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, value} -> value
      nil -> nil
    end
  end

  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1"]

  defp usage(script) do
    """
    Usage:
      #{script} [options]

    Local MOQX.Transport.Quicer self-pair calibration benchmark.

    Options:
      --profile NAME                 draft_14 or moq_lite_04 (default: draft_14)
      --host HOST                    Local listener/connect host (default: 127.0.0.1)
      --stream-count N               Number of streams for stream step
      --stream-direction DIR         auto, bidirectional, or unidirectional (default: auto)
      --payload-size BYTES           Stream payload chunk size (default: 1200)
      --payload-count N              Payload chunks per stream (default: 100)
      --datagram-size BYTES          Datagram payload size, including sequence prefix (default: 1200)
      --datagram-count N             Datagrams to send when profile supports datagrams (default: 1000)
      --timeout-ms N                 Per-operation timeout in milliseconds (default: 5000)
      --cert-dir PATH                Generated cert directory (default: #{@default_cert_dir})
      --certfile PATH                Existing TLS certificate PEM file
      --keyfile PATH                 Existing TLS private key PEM file
      --cacertfile PATH              Existing CA certificate PEM file
      --run-id ID                    Run identifier
      --output PATH                  Write JSONL to path instead of stdout
      --notes TEXT                   Notes copied into run metadata
      --help                         Show this help
    """
  end
end
