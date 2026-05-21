defmodule MOQX.TransportBench.Iperf3Baseline do
  @moduledoc false

  alias MOQX.TransportBench.BuildInfo
  alias MOQX.TransportBench.PathMetadata

  @default_script "moqx-transport-bench iperf3-baseline"
  @script_version "v1"
  @schema_version "transport-bench-v1"

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
          server: :string,
          port: :integer,
          local_server: :boolean,
          tcp: :boolean,
          udp: :boolean,
          no_tcp: :boolean,
          no_udp: :boolean,
          tcp_duration: :integer,
          udp_duration: :integer,
          udp_bitrates: :string,
          udp_length: :integer,
          reverse: :boolean,
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

      is_nil(opts[:server]) ->
        {:error, "Missing required --server HOST.\n\n#{usage(script)}"}

      true ->
        build_config(opts, argv, script)
    end
  end

  defp build_config(opts, argv, script) do
    tcp? = Keyword.get(opts, :tcp, true) && !Keyword.get(opts, :no_tcp, false)
    udp? = Keyword.get(opts, :udp, true) && !Keyword.get(opts, :no_udp, false)

    if !tcp? && !udp? do
      {:error, "At least one of TCP or UDP must be enabled."}
    else
      udp_bitrates = parse_bitrates(Keyword.get(opts, :udp_bitrates, "10M,50M,100M"))

      config = %{
        argv: argv,
        script: script,
        command: command_string(script, argv),
        server: opts[:server],
        port: Keyword.get(opts, :port, 5201),
        local_server?: Keyword.get(opts, :local_server, false),
        tcp?: tcp?,
        udp?: udp?,
        tcp_duration: Keyword.get(opts, :tcp_duration, 10),
        udp_duration: Keyword.get(opts, :udp_duration, 10),
        udp_bitrates: udp_bitrates,
        udp_length: opts[:udp_length],
        reverse?: Keyword.get(opts, :reverse, false),
        path_json: opts[:path_json],
        path_overrides: path_overrides(opts),
        run_id: opts[:run_id] || default_run_id(opts[:server]),
        output: opts[:output],
        notes: opts[:notes]
      }

      {:ok, config}
    end
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
    local_server = maybe_start_local_server(config)
    started_at = timestamp()

    records =
      try do
        config
        |> steps()
        |> Enum.with_index(1)
        |> Enum.map(fn {step, index} ->
          run_step(config, step, index, started_at)
        end)
      after
        stop_local_server(local_server)
      end

    write_records(records, config.output)
  end

  defp maybe_start_local_server(%{local_server?: false}), do: nil

  defp maybe_start_local_server(%{port: port}) do
    iperf3 = System.find_executable("iperf3") || raise "iperf3 not found on PATH"

    port_handle =
      Port.open({:spawn_executable, iperf3}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--server", "--port", Integer.to_string(port)]
      ])

    Process.sleep(300)
    drain_port(port_handle)
    port_handle
  end

  defp stop_local_server(nil), do: :ok

  defp stop_local_server(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp drain_port(port) do
    receive do
      {^port, {:data, _data}} -> drain_port(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      0 -> :ok
    end
  end

  defp steps(config) do
    tcp_steps =
      if config.tcp? do
        [%{protocol: "tcp", duration: config.tcp_duration, bitrate: nil, offered_load_bps: nil}]
      else
        []
      end

    udp_steps =
      if config.udp? do
        Enum.map(config.udp_bitrates, fn {raw, bps} ->
          %{protocol: "udp", duration: config.udp_duration, bitrate: raw, offered_load_bps: bps}
        end)
      else
        []
      end

    tcp_steps ++ udp_steps
  end

  defp run_step(config, step, index, run_started_at) do
    started_at = timestamp()
    {iperf_output, exit_status, iperf_args} = run_iperf3(config, step)
    finished_at = timestamp()
    decoded = decode_json(iperf_output)

    build_record(%{
      config: config,
      step: step,
      step_index: index,
      step_count: length(steps(config)),
      run_started_at: run_started_at,
      started_at: started_at,
      finished_at: finished_at,
      exit_status: exit_status,
      iperf_args: iperf_args,
      iperf_output: iperf_output,
      iperf_json: decoded
    })
  end

  defp run_iperf3(config, step) do
    base_args = [
      "--client",
      config.server,
      "--port",
      Integer.to_string(config.port),
      "--time",
      Integer.to_string(step.duration),
      "--json"
    ]

    protocol_args =
      case step.protocol do
        "tcp" ->
          []

        "udp" ->
          args = ["--udp", "--bitrate", step.bitrate]

          if config.udp_length do
            args ++ ["--length", Integer.to_string(config.udp_length)]
          else
            args
          end
      end

    reverse_args = if config.reverse?, do: ["--reverse"], else: []
    args = base_args ++ protocol_args ++ reverse_args
    {output, status} = System.cmd("iperf3", args, stderr_to_stdout: true)
    {output, status, ["iperf3" | args]}
  end

  defp build_record(ctx) do
    %{
      "schema_version" => @schema_version,
      "record_type" => "step_summary",
      "run" => run_metadata(ctx),
      "path" => path_metadata(ctx.config),
      "software" => software_metadata(),
      "profile" => profile_metadata(ctx.step),
      "workload" => workload_metadata(ctx.config, ctx.step),
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
      "finished_at" => ctx.finished_at,
      "git_sha" => BuildInfo.git_sha(),
      "script" => ctx.config.script,
      "script_version" => @script_version,
      "command" => ctx.config.command,
      "notes" => ctx.config.notes,
      "step_started_at" => ctx.started_at,
      "step_command" => Enum.join(ctx.iperf_args, " ")
    }
  end

  defp path_metadata(config) do
    base =
      case config.path_json do
        nil -> default_path(config)
        path -> load_path_json(path)
      end

    deep_merge(base, compact(config.path_overrides))
  end

  defp default_path(config) do
    loopback? = loopback?(config.server)

    evidence_tier =
      if loopback?, do: "loopback_calibration", else: "edge_to_server"

    %{
      "evidence_tier" => evidence_tier,
      "path_id" => "#{evidence_tier}-#{config.server}-#{config.port}",
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

  defp load_path_json(path) do
    PathMetadata.load_json!(path)
  end

  defp software_metadata do
    %{
      "elixir_version" => System.version(),
      "otp_version" => System.otp_release(),
      "moqx_version" => moqx_version(),
      "quicer_version" => nil,
      "msquic_version" => nil,
      "reference_implementation" => "iperf3",
      "reference_version" => iperf3_version()
    }
  end

  defp profile_metadata(step) do
    %{
      "name" => "path_baseline",
      "alpn" => nil,
      "datagrams" => step.protocol == "udp",
      "congestion_control" => nil,
      "pacing" => nil,
      "settings" => %{
        "tool" => "iperf3",
        "transport_protocol" => step.protocol
      }
    }
  end

  defp workload_metadata(config, step) do
    %{
      "family" => "path_baseline",
      "direction" => if(config.reverse?, do: "server_to_client", else: "client_to_server"),
      "stream_direction" => nil,
      "stream_count" => nil,
      "payload_size_bytes" => config.udp_length,
      "payloads_per_second" => nil,
      "offered_load_bps" => step.offered_load_bps,
      "datagram_size_bytes" => config.udp_length,
      "datagrams_per_second" => nil,
      "control_trickle_bps" => nil,
      "tool" => "iperf3",
      "transport_protocol" => step.protocol,
      "server" => config.server,
      "port" => config.port
    }
  end

  defp methodology_metadata(ctx) do
    %{
      "warmup_seconds" => 0,
      "step_seconds" => ctx.step.duration,
      "cooldown_seconds" => 0,
      "step_index" => ctx.step_index,
      "step_count" => ctx.step_count,
      "repetition_index" => 1,
      "repetition_count" => 1,
      "stop_conditions" => ["iperf3_nonzero_exit"]
    }
  end

  defp metrics(ctx) do
    summary = summary(ctx.iperf_json, ctx.step.protocol)
    sent = map_get(ctx.iperf_json, ["end", "sum_sent"], %{})
    received = map_get(ctx.iperf_json, ["end", "sum_received"], %{})
    cpu = map_get(ctx.iperf_json, ["end", "cpu_utilization_percent"], %{})
    duration = number(summary["seconds"]) || ctx.step.duration
    jitter_ms = number(summary["jitter_ms"])
    lost_count = number(summary["lost_packets"])
    packet_count = number(summary["packets"])

    %{
      "handshake_latency_ms" => nil,
      "first_byte_latency_ms" => nil,
      "offered_load_bps" => ctx.step.offered_load_bps,
      "goodput_bps" => goodput_bps(summary, received, sent),
      "send_rate_packets_per_second" => packet_send_rate(summary, sent, duration),
      "send_rate_datagrams_per_second" =>
        udp_only(ctx.step.protocol, rate(number(sent["packets"]) || packet_count, duration)),
      "delivered_datagrams_per_second" =>
        udp_only(ctx.step.protocol, rate(delivered_packets(packet_count, lost_count), duration)),
      "datagram_delivery_ratio" =>
        udp_only(ctx.step.protocol, delivery_ratio(summary, packet_count, lost_count)),
      "datagram_drop_count" => udp_only(ctx.step.protocol, lost_count),
      "datagram_late_count" => nil,
      "stream_count" => nil,
      "payload_size_bytes" => ctx.config.udp_length,
      "latency_p50_ms" => nil,
      "latency_p95_ms" => nil,
      "latency_p99_ms" => nil,
      "sender_cpu_percent" => number(cpu["host_total"]),
      "receiver_cpu_percent" => number(cpu["remote_total"]),
      "sender_memory_bytes" => nil,
      "receiver_memory_bytes" => nil,
      "sender_mailbox_depth" => nil,
      "receiver_mailbox_depth" => nil,
      "send_backpressure_ms" => nil,
      "stream_stall_count" => 0,
      "control_latency_p99_ms" => nil,
      "jitter_ms" => jitter_ms,
      "iperf3_retransmits" => number(summary["retransmits"]) || number(sent["retransmits"]),
      "iperf3_exit_status" => ctx.exit_status
    }
  end

  defp goodput_bps(summary, received, sent) do
    number(summary["bits_per_second"]) ||
      number(received["bits_per_second"]) ||
      number(sent["bits_per_second"])
  end

  defp packet_send_rate(summary, sent, duration) do
    rate(number(sent["packets"]) || number(summary["packets"]), duration)
  end

  defp delivery_ratio(summary, packet_count, lost_count) do
    lost_percent = number(summary["lost_percent"])

    cond do
      is_number(lost_percent) ->
        max(0.0, 1.0 - lost_percent / 100.0)

      is_number(packet_count) && packet_count > 0 && is_number(lost_count) ->
        (packet_count - lost_count) / packet_count

      true ->
        nil
    end
  end

  defp udp_only("udp", value), do: value
  defp udp_only(_protocol, _value), do: nil

  defp summary(nil, _protocol), do: %{}

  defp summary(json, "tcp") do
    map_get(json, ["end", "sum_received"], nil) ||
      map_get(json, ["end", "sum_sent"], nil) ||
      map_get(json, ["end", "sum"], %{})
  end

  defp summary(json, "udp") do
    map_get(json, ["end", "sum"], nil) ||
      map_get(json, ["end", "sum_received"], nil) ||
      map_get(json, ["end", "sum_sent"], %{})
  end

  defp limits(ctx) do
    failed? = ctx.exit_status != 0
    udp_loss? = get_in(metrics(ctx), ["datagram_delivery_ratio"]) not in [nil, 1.0]

    %{
      "first_break_symptom" => first_symptom(failed?, udp_loss?),
      "stopped_by" => if(failed?, do: "iperf3_nonzero_exit", else: nil),
      "connection_closed" => false,
      "protocol_error" => failed?,
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
        ctx.exit_status == 0 -> nil
        is_binary(ctx.iperf_output) && ctx.iperf_output != "" -> String.trim(ctx.iperf_output)
        true -> "iperf3 exited with status #{ctx.exit_status}"
      end

    %{
      "close_reason" => nil,
      "error_code" => ctx.exit_status,
      "message" => message
    }
  end

  defp first_symptom(true, _udp_loss?), do: "protocol_error"
  defp first_symptom(false, true), do: "datagram_delivery_loss"
  defp first_symptom(false, false), do: nil

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

  defp parse_bitrates(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn bitrate ->
      raw = String.trim(bitrate)
      {raw, bitrate_to_bps(raw)}
    end)
  end

  defp bitrate_to_bps(raw) do
    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)([kKmMgG]?)$/, raw) do
      [_, number, suffix] ->
        multiplier =
          case String.downcase(suffix) do
            "k" -> 1_000
            "m" -> 1_000_000
            "g" -> 1_000_000_000
            _ -> 1
          end

        round(String.to_float(decimal(number)) * multiplier)

      _ ->
        nil
    end
  end

  defp decimal(number) do
    if String.contains?(number, "."), do: number, else: number <> ".0"
  end

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

  defp map_get(nil, _path, default), do: default
  defp map_get(map, [], _default), do: map

  defp map_get(map, [key | rest], default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> map_get(value, rest, default)
      :error -> default
    end
  end

  defp map_get(_value, _path, default), do: default

  defp number(value) when is_integer(value) or is_float(value), do: value
  defp number(_), do: nil

  defp rate(nil, _seconds), do: nil
  defp rate(_count, seconds) when not is_number(seconds) or seconds <= 0, do: nil
  defp rate(count, seconds), do: count / seconds

  defp delivered_packets(nil, _lost), do: nil
  defp delivered_packets(packets, nil), do: packets
  defp delivered_packets(packets, lost), do: packets - lost

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

  defp default_run_id(server) do
    timestamp()
    |> String.replace(":", "-")
    |> String.replace(".", "-")
    |> Kernel.<>("-iperf3-#{server}")
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

  defp iperf3_version do
    case System.cmd("iperf3", ["--version"], stderr_to_stdout: true) do
      {text, 0} -> text |> String.split("\n", trim: true) |> List.first()
      _ -> nil
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

  defp loopback?(server), do: server in ["localhost", "127.0.0.1", "::1"]

  defp usage(script) do
    """
    Usage:
      #{script} --server HOST [options]

    Required:
      --server HOST                  iperf3 server host or IP

    Common options:
      --port PORT                    iperf3 port (default: 5201)
      --tcp-duration SECONDS         TCP test duration (default: 10)
      --udp-duration SECONDS         UDP step duration (default: 10)
      --udp-bitrates LIST            comma-separated UDP offered rates (default: 10M,50M,100M)
      --udp-length BYTES             UDP datagram size passed to iperf3 --length
      --no-tcp                       skip TCP baseline
      --no-udp                       skip UDP baseline
      --reverse                      ask iperf3 to run in reverse direction
      --local-server                 start a temporary local iperf3 server
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
        --server 127.0.0.1 --port 55201 --local-server \\
        --tcp-duration 1 --udp-duration 1 --udp-bitrates 1M
    """
  end
end
