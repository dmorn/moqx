unless Mix.env() == :test or Code.ensure_loaded?(Benchee) do
  Mix.raise("Benchee is not available. Run `mix deps.get` in bench/moqxprobe first.")
end

defmodule MOQXProbe.Bench.StreamClients do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info
  alias MOQX.Transport.Quicer
  alias MOQXProbe.Benchee.Adapters
  alias MOQXProbe.Benchee.EvidenceCollector
  alias MOQXProbe.Benchee.RunReceipt
  alias MOQXProbe.Benchee.RunMetadata
  alias MOQXProbe.Bench.StreamImplementations
  alias MOQXProbe.HostSampler
  alias MOQXProbe.Traffic
  alias MOQXProbe.Traffic.StreamPartitionSink
  alias MOQXProbe.Traffic.StreamSender

  @input_names ["flow-generated", "flow-prebuilt-list"]
  @implementation_names StreamImplementations.names()
  @target_names ["fake", "quicprobe"]
  @profile_name "draft14_object_stream"
  @quicprobe_experiment_lease_ttl_ms 30 * 60 * 1000
  @zero_evidence %{
    datagrams_received: 0,
    datagrams_echo_accepted: 0,
    datagram_bytes_received: 0,
    datagram_bytes_echo_accepted: 0,
    bidi_streams_accepted: 0,
    uni_streams_accepted: 0,
    streams_completed: 0,
    stream_bytes_received: 0,
    stream_bytes_echo_accepted: 0,
    stream_receive_error_count: 0,
    stream_send_error_count: 0,
    receiver_evidence_complete: true
  }
  @switches [
    help: :boolean,
    target: :string,
    host: :string,
    quic_port: :integer,
    iperf_port: :integer,
    ca: :string,
    servername: :string,
    alpn: :string,
    connect_timeout_ms: :integer,
    stream_count: :integer,
    payload_count: :integer,
    payload_size: :integer,
    stream_send_window: :integer,
    sender_shard_count: :integer,
    max_burst: :integer,
    max_queue_depth: :integer,
    flow_stages: :integer,
    min_demand: :integer,
    max_demand: :integer,
    idle_retries: :integer,
    event_batch_size: :integer,
    timeout_ms: :integer,
    input: :keep,
    implementation: :keep,
    benchee_warmup: :float,
    benchee_time: :float,
    benchee_memory_time: :float,
    benchee_reduction_time: :float,
    benchee_parallel: :integer,
    evidence_output: :string,
    evidence_timeout_ms: :integer,
    evidence_poll_ms: :integer,
    evidence_close_grace_ms: :integer,
    host_sample_ms: :integer,
    host_samples_output: :string,
    quicprobe_evidence_url: :string,
    quicprobe_evidence_port: :integer,
    quicprobe_evidence_path: :string,
    git_sha: :string,
    iperf_preflight_summary: :keep,
    tailscale_path_mode: :string,
    server_stats_path: :string,
    save: :string
  ]
  @aliases [h: :help]

  defmodule TimedRun do
    @moduledoc false

    defstruct [:receipt, :cleanup]
  end

  defmodule FlowSenderDispatcher do
    @moduledoc false

    use GenStage

    def start_link(opts) when is_list(opts) do
      GenStage.start_link(__MODULE__, opts)
    end

    def snapshot(dispatcher) do
      GenStage.call(dispatcher, :snapshot)
    end

    def stop(dispatcher) do
      if Process.alive?(dispatcher) do
        Process.unlink(dispatcher)
        GenStage.stop(dispatcher, :normal, 1_000)
      end

      :ok
    catch
      :exit, _reason -> :ok
    end

    @impl GenStage
    def init(opts) do
      {:consumer,
       %{
         routes: Keyword.fetch!(opts, :routes),
         routed_events: 0,
         unknown_stream_events: 0
       }}
    end

    @impl GenStage
    def handle_events(events, _from, state) do
      state = Enum.reduce(events, state, &route_event/2)
      {:noreply, [], state}
    end

    @impl GenStage
    def handle_call(:snapshot, _from, state) do
      {:reply, Map.take(state, [:routed_events, :unknown_stream_events]), [], state}
    end

    defp route_event(%{stream: stream} = event, state) do
      case Map.fetch(state.routes, raw_stream(stream)) do
        {:ok, worker} ->
          send(worker, {:moqxprobe_stream_payload, event})
          %{state | routed_events: state.routed_events + 1}

        :error ->
          %{state | unknown_stream_events: state.unknown_stream_events + 1}
      end
    end

    defp raw_stream(%MOQX.Transport.Conn.Stream{backend: %{data: raw_stream}}), do: raw_stream
  end

  defmodule FakeEvidenceState do
    @moduledoc false

    @counter_fields [
      :datagrams_received,
      :datagrams_echo_accepted,
      :datagram_bytes_received,
      :datagram_bytes_echo_accepted,
      :bidi_streams_accepted,
      :uni_streams_accepted,
      :streams_completed,
      :stream_bytes_received,
      :stream_bytes_echo_accepted,
      :stream_receive_error_count,
      :stream_send_error_count
    ]

    def start do
      :ets.new(__MODULE__, [
        :set,
        :public,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])
    end

    def stop(nil), do: :ok

    def stop(table) do
      if :ets.info(table) != :undefined do
        :ets.delete(table)
      end

      :ok
    end

    def record_stream_open(nil, _receipt_id, _direction), do: :ok
    def record_stream_open(_table, nil, _direction), do: :ok

    def record_stream_open(table, receipt_id, :bidirectional) do
      increment(table, receipt_id, :bidi_streams_accepted, 1)
    end

    def record_stream_open(table, receipt_id, :unidirectional) do
      increment(table, receipt_id, :uni_streams_accepted, 1)
    end

    def record_stream_open(_table, _receipt_id, _direction), do: :ok

    def record_stream_send(nil, _receipt_id, _byte_size, _finish?), do: :ok
    def record_stream_send(_table, nil, _byte_size, _finish?), do: :ok

    def record_stream_send(table, receipt_id, byte_size, finish?) do
      increment(table, receipt_id, :stream_bytes_received, byte_size)

      if finish? do
        increment(table, receipt_id, :streams_completed, 1)
      end

      :ok
    end

    def snapshot(table, receipt_id) do
      @counter_fields
      |> Map.new(fn field -> {field, counter(table, receipt_id, field)} end)
      |> Map.put(:receiver_evidence_complete, true)
    end

    defp increment(table, receipt_id, field, delta) do
      :ets.update_counter(table, {receipt_id, field}, {2, delta}, {{receipt_id, field}, 0})
      :ok
    end

    defp counter(table, receipt_id, field) do
      case :ets.lookup(table, {receipt_id, field}) do
        [{{^receipt_id, ^field}, value}] -> value
        [] -> 0
      end
    end
  end

  defmodule FakeTransport do
    @moduledoc false

    @behaviour Transport

    alias MOQXProbe.Bench.StreamClients.FakeEvidenceState

    @impl true
    def listen(_port, _opts), do: {:error, :unsupported}

    @impl true
    def local_address(_handle), do: {:error, :unsupported}

    @impl true
    def close_listener(_listener, _timeout), do: :ok

    @impl true
    def accept(_listener, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def handshake(connection, _timeout), do: {:ok, connection}

    @impl true
    def connect(_host, _port, opts, _timeout) do
      {:ok,
       {:fake_conn, make_ref(), option(opts, :evidence_table, nil),
        option(opts, :receipt_id, nil)}}
    end

    @impl true
    def open_stream({:fake_conn, conn_ref, evidence_table, receipt_id}, opts) do
      direction = option(opts, :direction, :unidirectional)
      FakeEvidenceState.record_stream_open(evidence_table, receipt_id, direction)
      {:ok, {:fake_stream, conn_ref, make_ref(), direction, evidence_table, receipt_id}}
    end

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(
          {:fake_stream, _conn_ref, _stream_ref, _direction, evidence_table, receipt_id} = stream,
          data,
          opts
        ) do
      FakeEvidenceState.record_stream_send(
        evidence_table,
        receipt_id,
        :erlang.iolist_size(data),
        option(opts, :finish, false) == true
      )

      send(self(), {:moqx_transport, {:stream_event, stream, :send_complete, false}})
      :ok
    end

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :unsupported}

    @impl true
    def send_datagram(_connection, _data), do: {:error, :unsupported}

    @impl true
    def send_datagram(_connection, _data, _opts), do: {:error, :unsupported}

    @impl true
    def finish_sending(_stream), do: :ok

    @impl true
    def abort_sending(_stream, _error_code), do: :ok

    @impl true
    def abort_receiving(_stream, _error_code), do: :ok

    @impl true
    def close_connection(_connection, _error_code), do: :ok

    @impl true
    def set_active(_stream, _active), do: :ok

    @impl true
    def controlling_process(_handle, _pid), do: :ok

    @impl true
    def normalize_message({:moqx_transport, event}), do: event
    def normalize_message(_message), do: :unknown

    @impl true
    def stream_info(
          {:fake_stream, _conn_ref, stream_ref, direction, _evidence_table, _receipt_id},
          local_role,
          initiator
        ) do
      {:ok,
       %Info{
         stream_id: :erlang.phash2(stream_ref),
         direction: direction,
         initiator: initiator,
         initiator_role: local_role,
         local_role: local_role,
         send_side?: true,
         receive_side?: direction == :bidirectional
       }}
    end

    @impl true
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}

    defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
    defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  end

  def run_context_owner(input) do
    input = Map.put_new(input, :implementation, "context_owner")
    started_at = receipt_timestamp(input)
    {ctx, streams, connection} = setup_streams(input)
    payload = payload(input)
    count = input.stream_count * input.payload_count

    {:ok, sender} =
      StreamSender.start(
        count: count,
        started_at_us: monotonic_us(),
        streams: streams,
        payload: payload,
        payload_count: input.payload_count,
        events: events(input, streams, payload),
        stream_send_window: input.stream_send_window,
        max_burst: input.max_burst,
        min_demand: input.min_demand,
        max_demand: input.max_demand,
        max_queue_depth: input.max_queue_depth,
        idle_retries: input.idle_retries,
        send_fun: context_owner_send_fun(),
        transport_state: %{ctx: ctx},
        event_forward_pid: self()
      )

    cleanup = fn ->
      _snapshot = StreamSender.stop(sender)
      maybe_evidence_close_grace(input)
      close_connection(ctx, connection)
      flush_mailbox()
    end

    result =
      try do
        drive_context_owner(sender, ctx, count, input)
      rescue
        exception ->
          if evidence_enabled?(input), do: cleanup.()
          reraise exception, __STACKTRACE__
      after
        unless evidence_enabled?(input), do: cleanup.()
      end

    maybe_run_receipt(input, result, started_at, cleanup)
  end

  def run_stream_owner(input) do
    input
    |> Map.put_new(:implementation, "stream_owner")
    |> run_flow_sender_topology("stream_owner", input.stream_count)
  end

  def run_sender_shards(input) do
    input
    |> Map.put_new(:implementation, "sender_shards")
    |> run_flow_sender_topology("sender_shards", input.sender_shard_count)
  end

  def run_flow_partitions(input) do
    input
    |> Map.put_new(:implementation, "flow_partitions")
    |> run_flow_partition_topology("flow_partitions", input.sender_shard_count)
  end

  defp run_flow_sender_topology(input, implementation, shard_count) do
    started_at = receipt_timestamp(input)
    {ctx, streams, connection} = setup_streams(input)
    payload = payload(input)
    deadline_us = monotonic_us() + input.timeout_ms * 1_000
    shard_groups = shard_streams(streams, shard_count)

    cleanup = fn ->
      maybe_evidence_close_grace(input)
      close_connection(ctx, connection)
      flush_mailbox()
    end

    result =
      try do
        {task_spawn_duration_us, shard_tasks} =
          timed(fn ->
            Enum.map(shard_groups, fn {shard_index, shard_streams} ->
              task =
                Task.async(fn ->
                  run_sender_shard(shard_index, shard_streams, input, deadline_us)
                end)

              {shard_index, shard_streams, task}
            end)
          end)

        routes = sender_shard_routes(shard_tasks)
        {:ok, dispatcher} = FlowSenderDispatcher.start_link(routes: routes)

        {:ok, producer} =
          Traffic.start_payloads(stream_events(input, streams, payload), dispatcher,
            mapper: & &1,
            stages: input.flow_stages,
            min_demand: input.min_demand,
            max_demand: input.max_demand
          )

        {task_await_duration_us, shard_results} =
          timed(fn ->
            shard_tasks
            |> Enum.map(fn {_shard_index, _streams, task} -> task end)
            |> Task.await_many(input.timeout_ms + 1_000)
          end)

        :ok = Traffic.await_payloads(producer, input.timeout_ms)
        dispatcher_snapshot = FlowSenderDispatcher.snapshot(dispatcher)
        :ok = FlowSenderDispatcher.stop(dispatcher)

        local_sender_flow_sender_summary(
          implementation,
          shard_results,
          shard_count,
          task_spawn_duration_us,
          task_await_duration_us,
          dispatcher_snapshot
        )
      rescue
        exception ->
          if evidence_enabled?(input), do: cleanup.()
          reraise exception, __STACKTRACE__
      after
        unless evidence_enabled?(input), do: cleanup.()
      end

    maybe_run_receipt(input, result, started_at, cleanup)
  end

  defp run_flow_partition_topology(input, implementation, shard_count) do
    started_at = receipt_timestamp(input)
    {ctx, streams, connection} = setup_streams(input)
    payload = payload(input)
    shard_groups = shard_streams(streams, shard_count)
    partition_count = length(shard_groups)

    cleanup = fn ->
      maybe_evidence_close_grace(input)
      close_connection(ctx, connection)
      flush_mailbox()
    end

    result =
      try do
        {sink_start_duration_us, sinks} =
          timed(fn -> start_partition_sinks(shard_groups, input) end)

        try do
          {:ok, producer} =
            Traffic.start_partitioned_payloads(
              partition_stream_events(input, streams, payload, partition_count),
              sinks,
              mapper: & &1,
              stages: input.flow_stages,
              partition_count: partition_count,
              hash: partition_hash(partition_count),
              min_demand: input.min_demand,
              max_demand: input.max_demand
            )

          {sink_await_duration_us, shard_results} =
            timed(fn -> await_partition_sinks(sinks, input.timeout_ms) end)

          case Traffic.await_payloads(producer, input.timeout_ms) do
            :ok ->
              local_sender_flow_partition_summary(
                implementation,
                shard_results,
                partition_count,
                sink_start_duration_us,
                sink_await_duration_us
              )

            {:error, reason} ->
              raise "flow_partitions producer failed: #{inspect(reason)}"
          end
        after
          stop_partition_sinks(sinks)
        end
      rescue
        exception ->
          if evidence_enabled?(input), do: cleanup.()
          reraise exception, __STACKTRACE__
      after
        unless evidence_enabled?(input), do: cleanup.()
      end

    maybe_run_receipt(input, result, started_at, cleanup)
  end

  def jobs(options) do
    all = %{
      "context_owner" => fn input ->
        input |> Map.put(:implementation, "context_owner") |> run_context_owner()
      end,
      "stream_owner" => fn input ->
        input |> Map.put(:implementation, "stream_owner") |> run_stream_owner()
      end,
      "sender_shards" => fn input ->
        input |> Map.put(:implementation, "sender_shards") |> run_sender_shards()
      end,
      "flow_partitions" => fn input ->
        input |> Map.put(:implementation, "flow_partitions") |> run_flow_partitions()
      end
    }

    Map.new(options.implementations, fn name -> {name, Map.fetch!(all, name)} end)
  end

  def inputs(options) do
    Map.new(options.inputs, fn name -> {name, input_for(name, options.base)} end)
  end

  def parse_cli!(argv) do
    argv = drop_mix_separator(argv)
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        IO.puts(help())
        System.halt(0)

      args != [] ->
        Mix.raise("unexpected positional arguments: #{Enum.join(args, " ")}\n\n#{help()}")

      invalid != [] ->
        invalid_text = Enum.map_join(invalid, ", ", fn {flag, value} -> "#{flag}=#{value}" end)
        Mix.raise("invalid options: #{invalid_text}\n\n#{help()}")

      true ->
        %{
          base: base_options(opts),
          inputs: selected_values(opts, :input, @input_names),
          implementations: selected_values(opts, :implementation, @implementation_names),
          benchee: benchee_options(opts)
        }
        |> put_evidence_options(opts)
        |> put_host_samples_options(opts)
    end
  end

  def benchee_config(options) do
    config = [
      inputs: inputs(options),
      warmup: options.benchee.warmup,
      time: options.benchee.time,
      memory_time: options.benchee.memory_time,
      reduction_time: options.benchee.reduction_time,
      parallel: options.benchee.parallel,
      print: [fast_warning: false]
    ]

    config = maybe_put_evidence_hooks(config, options)

    case options.benchee.save do
      nil -> config
      path -> Keyword.put(config, :save, path: path, tag: "stream-clients")
    end
  end

  def prepare_run!(options) do
    options = acquire_quicprobe_experiment_lease!(options)

    try do
      prepare_evidence!(options)
    rescue
      exception ->
        release_quicprobe_experiment_lease(options)
        reraise exception, __STACKTRACE__
    end
  end

  def prepare_evidence!(%{evidence: %{enabled?: false}} = options), do: options

  def prepare_evidence!(%{evidence: evidence} = options) do
    {:ok, collector} = EvidenceCollector.start(run_id: evidence.run_id)

    fake_state =
      case options.base.target do
        :fake -> FakeEvidenceState.start()
        :quicprobe -> nil
      end

    evidence = %{evidence | collector: collector, fake_state: fake_state}
    %{options | evidence: evidence}
  end

  def write_evidence!(%{evidence: %{enabled?: false}}), do: :ok

  def write_evidence!(%{evidence: %{collector: collector, output: output}}) do
    output |> Path.dirname() |> File.mkdir_p!()

    case EvidenceCollector.write_jsonl(collector, output) do
      :ok ->
        summary = EvidenceCollector.summary(collector)

        IO.puts(
          "Delivery evidence: wrote #{output} " <>
            "(total=#{summary.total}, valid=#{summary.valid}, invalid=#{summary.invalid}, " <>
            "timeout=#{summary.timeout}, error=#{summary.error})"
        )

        :ok

      {:error, reason} ->
        Mix.raise("failed to write delivery evidence sidecar #{output}: #{inspect(reason)}")
    end
  end

  def cleanup_evidence(%{evidence: %{collector: collector, fake_state: fake_state}}) do
    if collector, do: EvidenceCollector.stop(collector)
    FakeEvidenceState.stop(fake_state)
  end

  def cleanup_evidence(_options), do: :ok

  def cleanup_run(options) do
    try do
      cleanup_evidence(options)
    after
      release_quicprobe_experiment_lease(options)
    end
  end

  defp drop_mix_separator(["--" | argv]), do: argv
  defp drop_mix_separator(argv), do: argv

  defp base_options(opts) do
    max_burst = positive_integer(opts, :max_burst, 64)

    base = %{
      target: target(opts),
      host: Keyword.get(opts, :host, "127.0.0.1"),
      quic_port: positive_integer(opts, :quic_port, 4433),
      iperf_port: positive_integer(opts, :iperf_port, 5201),
      ca: Keyword.get(opts, :ca),
      servername: Keyword.get(opts, :servername, "localhost"),
      alpn: Keyword.get(opts, :alpn, "moqx-test"),
      connect_timeout_ms: positive_integer(opts, :connect_timeout_ms, 5_000),
      stream_count: positive_integer(opts, :stream_count, 32),
      payload_count: positive_integer(opts, :payload_count, 1_000),
      payload_size: positive_integer(opts, :payload_size, 1_180),
      stream_send_window: positive_integer(opts, :stream_send_window, 16),
      sender_shard_count:
        positive_integer(opts, :sender_shard_count, default_sender_shard_count(opts)),
      max_burst: max_burst,
      max_queue_depth: positive_integer(opts, :max_queue_depth, 256),
      flow_stages: positive_integer(opts, :flow_stages, 1),
      idle_retries: non_negative_integer(opts, :idle_retries, 1_000),
      event_batch_size: positive_integer(opts, :event_batch_size, 1_024),
      timeout_ms: positive_integer(opts, :timeout_ms, 15_000)
    }

    base
    |> Map.put(:git_sha, Keyword.get(opts, :git_sha, RunMetadata.git_sha()))
    |> Map.put(
      :iperf3_preflight,
      RunMetadata.iperf3_summaries(Keyword.get_values(opts, :iperf_preflight_summary))
    )
    |> Map.put(:tailscale_path_mode, Keyword.get(opts, :tailscale_path_mode))
    |> Map.put(:server_stats_path, Keyword.get(opts, :server_stats_path))
    |> Map.put(:min_demand, non_negative_integer(opts, :min_demand, max(base.max_burst - 1, 0)))
    |> Map.put(:max_demand, positive_integer(opts, :max_demand, base.max_burst))
    |> validate_flow_demand!()
    |> validate_flow_stages!()
    |> validate_target!()
  end

  defp benchee_options(opts) do
    %{
      warmup: non_negative_float(opts, :benchee_warmup, 1.0),
      time: positive_float(opts, :benchee_time, 3.0),
      memory_time: non_negative_float(opts, :benchee_memory_time, 0.0),
      reduction_time: non_negative_float(opts, :benchee_reduction_time, 0.0),
      parallel: positive_integer(opts, :benchee_parallel, 1),
      save: Keyword.get(opts, :save)
    }
  end

  defp put_evidence_options(%{base: base} = options, opts) do
    output = Keyword.get(opts, :evidence_output)
    enabled? = is_binary(output)
    quicprobe_evidence_url = quicprobe_evidence_url(base, opts)
    quicprobe_evidence_path = Keyword.get(opts, :quicprobe_evidence_path)

    if enabled? and options.benchee.parallel != 1 do
      Mix.raise("--evidence-output requires --benchee-parallel 1")
    end

    Map.put(options, :evidence, %{
      enabled?: enabled?,
      output: output,
      timeout_ms: positive_integer(opts, :evidence_timeout_ms, 5_000),
      poll_ms: positive_integer(opts, :evidence_poll_ms, 50),
      close_grace_ms:
        non_negative_integer(
          opts,
          :evidence_close_grace_ms,
          default_evidence_close_grace_ms(base.target)
        ),
      quicprobe_evidence_url: quicprobe_evidence_url,
      quicprobe_evidence_path: quicprobe_evidence_path,
      quicprobe_experiment_lease: nil,
      run_id: evidence_run_id(),
      collector: nil,
      fake_state: nil
    })
  end

  defp put_host_samples_options(options, opts) do
    interval_ms = non_negative_integer(opts, :host_sample_ms, 0)
    output = Keyword.get(opts, :host_samples_output)
    enabled? = interval_ms > 0 and is_binary(output)

    if interval_ms > 0 and not is_binary(output) do
      Mix.raise("--host-sample-ms requires --host-samples-output PATH")
    end

    if enabled? and options.benchee.parallel != 1 do
      Mix.raise("--host-samples-output requires --benchee-parallel 1")
    end

    Map.put(options, :host_samples, %{
      enabled?: enabled?,
      interval_ms: interval_ms,
      output: output,
      sampler: nil
    })
  end

  @doc """
  Starts the out-of-band BEAM/host sampler in its own process before the
  measured suite, monitoring the suite driver process under a stable role
  label. Returns the updated options. No-op when host sampling is disabled.

  The sampler never runs inside the timed Benchee function or a telemetry
  handler (ADR-0009 observer-effect rule); it samples the driver process from
  the outside on a fixed interval.
  """
  def start_host_sampler(%{host_samples: %{enabled?: false}} = options), do: options

  def start_host_sampler(%{host_samples: host_samples} = options) do
    {:ok, sampler} =
      HostSampler.start_link(
        interval_ms: host_samples.interval_ms,
        output: host_samples.output,
        roles: [{"benchee_suite_driver", self()}]
      )

    put_in(options, [:host_samples, :sampler], sampler)
  end

  def start_host_sampler(options), do: options

  @doc """
  Stops the host sampler, flushing the sidecar. Safe to call when sampling was
  never started.
  """
  def stop_host_sampler(%{host_samples: %{sampler: sampler, output: output}})
      when is_pid(sampler) do
    :ok = HostSampler.stop(sampler)
    IO.puts("Host samples: wrote #{output}")
    :ok
  end

  def stop_host_sampler(_options), do: :ok

  defp maybe_put_evidence_hooks(config, %{evidence: %{enabled?: false}}), do: config

  defp maybe_put_evidence_hooks(config, options) do
    config
    |> Keyword.put(:before_each, evidence_before_each(options))
    |> Keyword.put(:after_each, evidence_after_each(options))
  end

  defp evidence_before_each(%{evidence: evidence, base: %{target: :fake}}) do
    fn input ->
      receipt_id = receipt_id(input)

      input
      |> Map.put(:evidence_enabled?, true)
      |> Map.put(:receipt_id, receipt_id)
      |> Map.put(:evidence_table, evidence.fake_state)
      |> Map.put(:evidence_close_grace_ms, evidence.close_grace_ms)
    end
  end

  defp evidence_before_each(%{evidence: evidence, base: %{target: :quicprobe}}) do
    fn input ->
      receipt_id = receipt_id(input)
      after_run_sequence = quicprobe_evidence_cursor(evidence)

      input
      |> Map.put(:evidence_enabled?, true)
      |> Map.put(:receipt_id, receipt_id)
      |> Map.put(:quicprobe_after_run_sequence, after_run_sequence)
      |> Map.put(:evidence_close_grace_ms, evidence.close_grace_ms)
      |> Map.put(:quicprobe_evidence_url, evidence.quicprobe_evidence_url)
      |> Map.put(:quicprobe_evidence_path, evidence.quicprobe_evidence_path)
      |> Map.put(:quicprobe_experiment_lease, evidence.quicprobe_experiment_lease)
    end
  end

  defp evidence_after_each(%{evidence: evidence, base: %{target: :fake}}) do
    evidence_after_each_fun(evidence, Adapters.FakeTransport,
      source: fn receipt -> FakeEvidenceState.snapshot(evidence.fake_state, receipt.id) end
    )
  end

  defp evidence_after_each(%{evidence: evidence, base: %{target: :quicprobe}}) do
    evidence_after_each_fun(evidence, Adapters.Quicprobe, quicprobe_evidence_opts(evidence))
  end

  defp evidence_after_each_fun(evidence, adapter, adapter_opts) do
    fn
      %TimedRun{receipt: receipt, cleanup: cleanup} ->
        cleanup.()
        _ = EvidenceCollector.collect(evidence.collector, adapter, receipt, adapter_opts)
        receipt

      %RunReceipt{} = receipt ->
        _ = EvidenceCollector.collect(evidence.collector, adapter, receipt, adapter_opts)
        receipt

      other ->
        other
    end
  end

  defp quicprobe_evidence_cursor(evidence) do
    case Adapters.Quicprobe.last_run_sequence(quicprobe_evidence_opts(evidence)) do
      {:ok, sequence} -> sequence
      {:error, _reason} -> 0
    end
  end

  defp quicprobe_evidence_opts(evidence) do
    [
      url: evidence.quicprobe_evidence_url,
      path: evidence.quicprobe_evidence_path,
      timeout_ms: evidence.timeout_ms,
      poll_ms: evidence.poll_ms
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp acquire_quicprobe_experiment_lease!(
         %{base: %{target: :quicprobe} = base, evidence: evidence} = options
       ) do
    owner = "#{@profile_name}:#{evidence.run_id}"

    opts = [
      url: evidence.quicprobe_evidence_url,
      owner: owner,
      ttl_ms: @quicprobe_experiment_lease_ttl_ms,
      timeout_ms: evidence.timeout_ms,
      metadata: %{
        "profile" => @profile_name,
        "git_sha" => base.git_sha,
        "host" => base.host,
        "quic_port" => Integer.to_string(base.quic_port)
      }
    ]

    case Adapters.Quicprobe.acquire_experiment_lease(opts) do
      {:ok, lease} ->
        put_in(options, [:evidence, :quicprobe_experiment_lease], lease)

      {:error, {:quicprobe_experiment_lease_busy, response}} ->
        Mix.raise(
          quicprobe_experiment_lease_busy_message(evidence.quicprobe_evidence_url, response)
        )

      {:error, reason} ->
        Mix.raise(
          "failed to acquire quicprobe experiment lease at #{evidence.quicprobe_evidence_url}: " <>
            inspect(reason)
        )
    end
  end

  defp acquire_quicprobe_experiment_lease!(options), do: options

  defp release_quicprobe_experiment_lease(%{
         base: %{target: :quicprobe},
         evidence: %{quicprobe_experiment_lease: lease} = evidence
       })
       when is_map(lease) do
    opts = [url: evidence.quicprobe_evidence_url, timeout_ms: evidence.timeout_ms]

    case Adapters.Quicprobe.release_experiment_lease(opts, lease) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.warn("failed to release quicprobe experiment lease: #{inspect(reason)}")
    end
  end

  defp release_quicprobe_experiment_lease(_options), do: :ok

  defp quicprobe_experiment_lease_busy_message(url, response) do
    owner = get_in(response, ["lease", "owner"]) || "unknown owner"

    "quicprobe target #{url} is already leased by #{owner}; " <>
      "parallel experiments against the same quicprobe corrupt evidence readings"
  end

  defp quicprobe_evidence_url(%{target: :quicprobe, host: host}, opts) do
    cond do
      Keyword.has_key?(opts, :quicprobe_evidence_url) ->
        Keyword.fetch!(opts, :quicprobe_evidence_url)

      true ->
        default_quicprobe_evidence_url(
          host,
          positive_integer(opts, :quicprobe_evidence_port, 55_434)
        )
    end
  end

  defp quicprobe_evidence_url(_base, opts) do
    Keyword.get(opts, :quicprobe_evidence_url)
  end

  defp default_quicprobe_evidence_url(host, port) do
    "http://#{url_host(host)}:#{port}"
  end

  defp url_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[#{host}]"
    else
      host
    end
  end

  defp evidence_run_id do
    iso =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace("Z", "")

    "#{iso}-#{System.unique_integer([:positive])}"
  end

  defp default_evidence_close_grace_ms(:quicprobe), do: 25
  defp default_evidence_close_grace_ms(_target), do: 0

  defp positive_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      value
    else
      Mix.raise("--#{cli_key(key)} must be a positive integer")
    end
  end

  defp non_negative_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value >= 0 do
      value
    else
      Mix.raise("--#{cli_key(key)} must be a non-negative integer")
    end
  end

  defp positive_float(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_number(value) and value > 0 do
      value
    else
      Mix.raise("--#{cli_key(key)} must be a positive number")
    end
  end

  defp non_negative_float(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_number(value) and value >= 0 do
      value
    else
      Mix.raise("--#{cli_key(key)} must be a non-negative number")
    end
  end

  defp validate_flow_demand!(%{min_demand: min_demand, max_demand: max_demand} = options) do
    if min_demand <= max_demand do
      options
    else
      Mix.raise("--min-demand must be less than or equal to --max-demand")
    end
  end

  defp validate_flow_stages!(%{flow_stages: 1} = options), do: options

  defp validate_flow_stages!(%{flow_stages: flow_stages}) do
    Mix.raise(
      "--flow-stages #{flow_stages} is unsafe for ordered stream workloads; " <>
        "multiple source stages can reorder payloads for one stream and send FIN before " <>
        "earlier payloads"
    )
  end

  defp cli_key(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp target(opts) do
    case Keyword.get(opts, :target, "fake") do
      name when name in @target_names -> String.to_atom(name)
      name -> Mix.raise("--target must be one of #{Enum.join(@target_names, ", ")}; got #{name}")
    end
  end

  defp validate_target!(%{target: :quicprobe, ca: nil}) do
    Mix.raise("--ca is required when --target quicprobe")
  end

  defp validate_target!(options), do: options

  defp selected_values(opts, key, allowed) do
    values = Keyword.get_values(opts, key)
    values = if values == [], do: allowed, else: values
    unknown = values -- allowed

    if unknown != [] do
      Mix.raise(
        "#{key} must be one of #{Enum.join(allowed, ", ")}; got #{Enum.join(unknown, ", ")}"
      )
    end

    values
  end

  defp input_for("flow-generated", base), do: Map.put(base, :producer, :flow_generated)

  defp input_for("flow-prebuilt-list", base), do: Map.put(base, :producer, :flow_prebuilt_list)

  defp setup_streams(%{target: :fake} = input) do
    {:ok, ctx} = Transport.new(FakeTransport, fake_transport_opts(input))
    {:ok, connection, ctx} = Transport.connect(ctx, "localhost", 4433, [], 1_000)
    open_streams(ctx, connection, input)
  end

  defp setup_streams(%{target: :quicprobe} = input) do
    {:ok, ctx} = Transport.new(Quicer, [])

    {:ok, connection, ctx} =
      Transport.connect(
        ctx,
        input.host,
        input.quic_port,
        quicprobe_connect_opts(input),
        input.connect_timeout_ms
      )

    open_streams(ctx, connection, input)
  end

  defp open_streams(ctx, connection, input) do
    Enum.reduce(1..input.stream_count, {[], ctx}, fn index, {streams, ctx} ->
      {:ok, stream, ctx} = Transport.open_stream(ctx, connection, direction: :unidirectional)
      {[%{stream: stream, index: index} | streams], ctx}
    end)
    |> then(fn {streams, ctx} -> {ctx, Enum.reverse(streams), connection} end)
  end

  defp quicprobe_connect_opts(input) do
    [
      alpn: input.alpn,
      cacertfile: input.ca,
      verify: :verify_peer,
      server_name: input.servername,
      peer_bidi_stream_count: max(input.stream_count + 2, 10),
      peer_unidi_stream_count: max(input.stream_count + 2, 10)
    ]
  end

  defp fake_transport_opts(input) do
    [
      evidence_table: Map.get(input, :evidence_table),
      receipt_id: Map.get(input, :receipt_id)
    ]
  end

  defp close_connection(ctx, connection) do
    case Transport.close_connection(ctx, connection, 0) do
      {:ok, _ctx} -> :ok
      {:error, _reason, _ctx} -> :ok
    end
  end

  defp context_owner_send_fun do
    fn event, %{ctx: ctx} = transport_state ->
      result = Transport.send_stream(ctx, event.stream, event.payload, finish: event.finish?)

      case result do
        {:ok, send, ctx} -> {:ok, send, %{transport_state | ctx: ctx}}
        {:error, reason, ctx} -> {:error, reason, %{transport_state | ctx: ctx}}
      end
    end
  end

  defp drive_context_owner(sender, ctx, count, input) do
    drive_context_owner(sender, ctx, count, input, monotonic_us() + input.timeout_ms * 1_000)
  end

  defp drive_context_owner(sender, _ctx, count, input, deadline_us) do
    {:ok, snapshot} = StreamSender.drain(sender)
    ctx = snapshot.transport_state.ctx
    {ctx, completions} = collect_context_owner_completions(ctx, input.event_batch_size)

    {:ok, snapshot} =
      if completions == [] do
        {:ok, snapshot}
      else
        sender = StreamSender.update_transport_state(sender, &Map.put(&1, :ctx, ctx))
        StreamSender.complete_many(sender, completions, drain?: false)
      end

    cond do
      snapshot.completed >= count ->
        local_sender_context_owner_summary(snapshot)

      monotonic_us() >= deadline_us ->
        raise "context_owner benchmark timed out with #{snapshot.completed}/#{count} completions"

      completions == [] ->
        receive do
        after
          0 -> :ok
        end

        drive_context_owner(sender, ctx, count, input, deadline_us)

      true ->
        drive_context_owner(sender, ctx, count, input, deadline_us)
    end
  end

  defp collect_context_owner_completions(ctx, batch_size) do
    collect_context_owner_completions(ctx, %{}, batch_size)
  end

  defp collect_context_owner_completions(ctx, completions, remaining) when remaining <= 0 do
    {ctx, completion_list(completions)}
  end

  defp collect_context_owner_completions(ctx, completions, remaining) do
    case Transport.receive_event(ctx, 0) do
      {:ok, {:stream_event, stream, :send_completed, _metadata}, ctx} ->
        collect_context_owner_completions(
          ctx,
          Map.update(completions, stream, 1, &(&1 + 1)),
          remaining - 1
        )

      {:ok, _event, ctx} ->
        collect_context_owner_completions(ctx, completions, remaining - 1)

      {:unknown, _message, ctx} ->
        collect_context_owner_completions(ctx, completions, remaining - 1)

      {:error, _reason, ctx} ->
        collect_context_owner_completions(ctx, completions, remaining - 1)

      {:timeout, ctx} ->
        {ctx, completion_list(completions)}
    end
  end

  defp shard_streams(streams, shard_count) do
    shard_count = min(max(shard_count, 1), length(streams))

    1..shard_count
    |> Map.new(&{&1, []})
    |> then(fn initial ->
      streams
      |> Enum.with_index()
      |> Enum.reduce(initial, fn {stream, index}, shards ->
        shard_index = rem(index, shard_count) + 1
        Map.update!(shards, shard_index, &[stream | &1])
      end)
    end)
    |> Enum.map(fn {shard_index, streams} -> {shard_index, Enum.reverse(streams)} end)
  end

  defp start_partition_sinks(shard_groups, input) do
    Enum.map(shard_groups, fn {shard_index, streams} ->
      partition = shard_index - 1

      {:ok, sink} =
        StreamPartitionSink.start_link(
          partition: partition,
          shard_index: shard_index,
          streams: streams,
          payload_count: input.payload_count,
          stream_send_window: input.stream_send_window,
          max_queue_depth: input.max_queue_depth,
          notify_pid: self()
        )

      {partition, sink}
    end)
  end

  defp stop_partition_sinks(sinks) do
    Enum.each(sinks, fn {_partition, sink} -> StreamPartitionSink.stop(sink) end)
  end

  defp partition_hash(partition_count) do
    fn event ->
      partition = Map.get(event, :partition) || rem(event.stream_index - 1, partition_count)
      {event, partition}
    end
  end

  defp await_partition_sinks(sinks, timeout_ms) do
    monitors = Map.new(sinks, fn {_partition, sink} -> {Process.monitor(sink), sink} end)
    deadline_us = monotonic_us() + timeout_ms * 1_000

    try do
      monitors
      |> collect_partition_sinks(%{}, deadline_us)
      |> Map.values()
      |> Enum.sort_by(& &1.shard_index)
    after
      Enum.each(Map.keys(monitors), &Process.demonitor(&1, [:flush]))
    end
  end

  defp collect_partition_sinks(monitors, snapshots, _deadline_us)
       when map_size(monitors) == map_size(snapshots),
       do: snapshots

  defp collect_partition_sinks(monitors, snapshots, deadline_us) do
    timeout_ms = max(div(deadline_us - monotonic_us(), 1_000), 0)

    receive do
      {:moqxprobe_stream_partition_sink_done, sink, partition, snapshot} ->
        if Enum.member?(Map.values(monitors), sink) do
          collect_partition_sinks(
            monitors,
            Map.put(snapshots, partition, snapshot),
            deadline_us
          )
        else
          collect_partition_sinks(monitors, snapshots, deadline_us)
        end

      {:DOWN, ref, :process, sink, :normal} ->
        if Map.get(monitors, ref) == sink do
          collect_partition_sinks(monitors, snapshots, deadline_us)
        else
          collect_partition_sinks(monitors, snapshots, deadline_us)
        end

      {:DOWN, ref, :process, sink, reason} ->
        if Map.get(monitors, ref) == sink do
          raise "flow_partitions sink #{inspect(sink)} exited: #{inspect(reason)}"
        else
          collect_partition_sinks(monitors, snapshots, deadline_us)
        end
    after
      timeout_ms ->
        raise "flow_partitions completion timeout with #{map_size(snapshots)}/#{map_size(monitors)} shard snapshots"
    end
  end

  defp sender_shard_routes(shard_tasks) do
    Map.new(
      for {_shard_index, streams, %Task{pid: pid}} <- shard_tasks,
          %{stream: stream} <- streams do
        {raw_stream(stream), pid}
      end
    )
  end

  defp run_sender_shard(shard_index, streams, input, deadline_us) do
    started_at_us = monotonic_us()

    state =
      %{
        shard_index: shard_index,
        backend: shard_backend(streams),
        streams: sender_shard_stream_states(streams, input),
        receive_calls: 0,
        ready_drain_calls: 0,
        schedule_rounds: 0,
        payload_events: 0,
        completion_events: 0,
        send_cancelled_events: 0,
        orphan_completion_events: 0,
        ignored_events: 0,
        unknown_events: 0
      }
      |> drive_sender_shard(input, deadline_us)

    state
    |> sender_shard_result(input)
    |> Map.put(:duration_us, monotonic_us() - started_at_us)
  end

  defp shard_backend([%{stream: %Stream{backend: backend}} | _streams]), do: backend.module

  defp sender_shard_stream_states(streams, input) do
    Map.new(streams, fn %{stream: stream, index: index} ->
      {:ok, sender} = Stream.sender(stream)

      {raw_stream(stream),
       %{
         sender: sender,
         stream_index: index,
         stream_send_window: input.stream_send_window,
         accepted: 0,
         completed: 0,
         in_flight: 0,
         max_in_flight: 0,
         queued: :queue.new(),
         max_queue_depth: 0,
         send_calls: 0
       }}
    end)
  end

  defp drive_sender_shard(state, input, deadline_us) when is_map(state) do
    cond do
      sender_shard_complete?(state, input) ->
        state

      monotonic_us() >= deadline_us ->
        raise "sender_shards benchmark timed out with #{sender_shard_completed(state)}/#{sender_shard_expected(input, state)} completions"

      true ->
        state
        |> receive_sender_shard_batch(input, deadline_us)
        |> drive_sender_shard(input, deadline_us)
    end
  end

  defp sender_shard_complete?(state, input) do
    Enum.all?(state.streams, fn {_raw_stream, stream_state} ->
      stream_state.completed >= input.payload_count
    end)
  end

  defp receive_sender_shard_batch(state, input, deadline_us) do
    timeout_ms = max(div(deadline_us - monotonic_us(), 1_000), 0)
    state = %{state | receive_calls: state.receive_calls + 1}

    case receive_sender_shard_message(state, timeout_ms) do
      {:ok, state} -> drain_ready_sender_shard(state, input.event_batch_size - 1)
      {:timeout, _state} -> raise "sender_shards completion timeout"
    end
  end

  defp drain_ready_sender_shard(state, remaining) when remaining <= 0, do: state

  defp drain_ready_sender_shard(state, remaining) do
    state = %{state | ready_drain_calls: state.ready_drain_calls + 1}

    case receive_sender_shard_message(state, 0) do
      {:ok, state} -> drain_ready_sender_shard(state, remaining - 1)
      {:timeout, state} -> state
    end
  end

  defp receive_sender_shard_message(state, timeout_ms) do
    receive do
      message -> {:ok, handle_sender_shard_message(state, message)}
    after
      timeout_ms -> {:timeout, state}
    end
  end

  defp handle_sender_shard_message(state, message) do
    case message do
      {:moqxprobe_stream_payload, event} ->
        enqueue_sender_shard_payload(state, event)

      _other ->
        handle_sender_shard_backend_message(state, message)
    end
  end

  defp handle_sender_shard_backend_message(state, message) do
    case state.backend.normalize_message(message) do
      {:stream_event, raw_stream, :send_complete, false} ->
        complete_sender_shard_stream(state, raw_stream)

      {:stream_event, raw_stream, :send_complete, true} ->
        cancel_sender_shard_stream(state, raw_stream)

      {:stream_event, raw_stream, _event, _metadata} ->
        update_sender_shard_stream_event(state, raw_stream, :ignored_events)

      :unknown ->
        %{state | unknown_events: state.unknown_events + 1}

      _event ->
        %{state | ignored_events: state.ignored_events + 1}
    end
  end

  defp enqueue_sender_shard_payload(state, event) do
    raw_stream = raw_stream(event.stream)

    state
    |> update_sender_shard_stream_event(raw_stream, :payload_events, fn stream_state ->
      queued = :queue.in(event, stream_state.queued)

      stream_state
      |> Map.put(:queued, queued)
      |> Map.put(:max_queue_depth, max(stream_state.max_queue_depth, :queue.len(queued)))
      |> schedule_sender_shard_stream()
    end)
    |> Map.update!(:schedule_rounds, &(&1 + 1))
  end

  defp schedule_sender_shard_stream(stream_state) do
    do_schedule_sender_shard_stream(stream_state)
  end

  defp do_schedule_sender_shard_stream(stream_state) do
    case :queue.out(stream_state.queued) do
      {{:value, event}, queued} when stream_state.in_flight < stream_state.stream_send_window ->
        send_sender_shard_event(%{stream_state | queued: queued}, event)
        |> do_schedule_sender_shard_stream()

      {{:value, event}, queued} ->
        %{stream_state | queued: :queue.in_r(event, queued)}

      {:empty, _queued} ->
        stream_state
    end
  end

  defp send_sender_shard_event(stream_state, event) do
    opts = if event.finish?, do: [finish: true], else: []
    {:ok, _send, sender} = Stream.Sender.send(stream_state.sender, event.payload, opts)
    in_flight = stream_state.in_flight + 1

    %{
      stream_state
      | sender: sender,
        accepted: stream_state.accepted + 1,
        in_flight: in_flight,
        max_in_flight: max(stream_state.max_in_flight, in_flight),
        send_calls: stream_state.send_calls + 1
    }
  end

  defp complete_sender_shard_stream(state, raw_stream) do
    update_sender_shard_stream_event(state, raw_stream, :completion_events, fn stream_state ->
      case pop_sender_shard_pending_send(stream_state.sender) do
        {:ok, sender} ->
          %{
            stream_state
            | sender: sender,
              completed: stream_state.completed + 1,
              in_flight: max(stream_state.in_flight - 1, 0)
          }
          |> schedule_sender_shard_stream()

        :empty ->
          stream_state
      end
    end)
    |> Map.update!(:schedule_rounds, &(&1 + 1))
  end

  defp cancel_sender_shard_stream(state, raw_stream) do
    update_sender_shard_stream_event(state, raw_stream, :send_cancelled_events, fn stream_state ->
      case pop_sender_shard_pending_send(stream_state.sender) do
        {:ok, sender} ->
          %{stream_state | sender: sender, in_flight: max(stream_state.in_flight - 1, 0)}
          |> schedule_sender_shard_stream()

        :empty ->
          stream_state
      end
    end)
    |> Map.update!(:schedule_rounds, &(&1 + 1))
  end

  defp update_sender_shard_stream_event(
         state,
         raw_stream,
         counter,
         fun \\ fn stream_state ->
           stream_state
         end
       ) do
    case Map.fetch(state.streams, raw_stream) do
      {:ok, stream_state} ->
        streams = Map.put(state.streams, raw_stream, fun.(stream_state))
        %{state | streams: streams} |> increment_sender_shard_counter(counter)

      :error ->
        %{state | orphan_completion_events: state.orphan_completion_events + 1}
    end
  end

  defp increment_sender_shard_counter(state, :payload_events),
    do: %{state | payload_events: state.payload_events + 1}

  defp increment_sender_shard_counter(state, :completion_events),
    do: %{state | completion_events: state.completion_events + 1}

  defp increment_sender_shard_counter(state, :send_cancelled_events),
    do: %{state | send_cancelled_events: state.send_cancelled_events + 1}

  defp increment_sender_shard_counter(state, :ignored_events),
    do: %{state | ignored_events: state.ignored_events + 1}

  defp pop_sender_shard_pending_send(sender) do
    case :queue.out(sender.pending_sends) do
      {{:value, _send}, remaining} -> {:ok, %{sender | pending_sends: remaining}}
      {:empty, _queue} -> :empty
    end
  end

  defp sender_shard_result(state, input) do
    stream_results = Map.values(state.streams)

    %{
      shard_index: state.shard_index,
      stream_count: length(stream_results),
      accepted: sum_field(stream_results, :accepted),
      completed: sum_field(stream_results, :completed),
      in_flight: sum_field(stream_results, :in_flight),
      max_in_flight: max_field(stream_results, :max_in_flight),
      max_queue_depth: max_field(stream_results, :max_queue_depth),
      send_calls: sum_field(stream_results, :send_calls),
      payload_events: state.payload_events,
      completion_events: state.completion_events,
      send_cancelled_events: state.send_cancelled_events,
      orphan_completion_events: state.orphan_completion_events,
      ignored_events: state.ignored_events,
      unknown_events: state.unknown_events,
      receive_calls: state.receive_calls,
      ready_drain_calls: state.ready_drain_calls,
      schedule_rounds: state.schedule_rounds,
      expected: sender_shard_expected(input, state)
    }
  end

  defp sender_shard_completed(state) do
    state.streams
    |> Map.values()
    |> sum_field(:completed)
  end

  defp sender_shard_expected(input, state), do: map_size(state.streams) * input.payload_count

  defp raw_stream(%Stream{backend: %{data: raw_stream}}), do: raw_stream

  defp local_sender_context_owner_summary(snapshot) do
    "context_owner"
    |> implementation_summary()
    |> Map.merge(%{
      accepted: snapshot.accepted,
      completed: snapshot.completed,
      errors: snapshot.errors,
      in_flight: snapshot.in_flight,
      queue_depth: snapshot.queue_depth,
      outstanding_demand: snapshot.outstanding_demand,
      max_queue_depth: snapshot.max_queue_depth,
      stream_send_window: snapshot.stream_send_window,
      stop_reason: encode_atom(snapshot.stop_reason),
      stream_window_limited_tick_count: snapshot.stream_window_limited_tick_count,
      pacer: pacer_summary(snapshot.pacer),
      bursts: count_summary(snapshot.burst_counts),
      burst_duration_us: count_summary(snapshot.burst_durations_us),
      tick_lag_ms: count_summary(snapshot.tick_lags_ms),
      tick_due_count: count_summary(snapshot.tick_due_counts),
      tick_send_count: count_summary(snapshot.tick_send_counts)
    })
  end

  defp local_sender_flow_sender_summary(
         implementation,
         shard_results,
         configured_shard_count,
         task_spawn_duration_us,
         task_await_duration_us,
         dispatcher_snapshot
       ) do
    implementation
    |> implementation_summary()
    |> Map.merge(%{
      accepted: sum_field(shard_results, :accepted),
      completed: sum_field(shard_results, :completed),
      in_flight: sum_field(shard_results, :in_flight),
      configured_shard_count: configured_shard_count,
      active_shard_count: length(shard_results),
      streams_per_shard: count_summary(map_field(shard_results, :stream_count)),
      max_shard_in_flight: max_field(shard_results, :max_in_flight),
      max_shard_queue_depth: max_field(shard_results, :max_queue_depth),
      task_spawn_duration_us: task_spawn_duration_us,
      task_await_duration_us: task_await_duration_us,
      shard_duration_us: count_summary(map_field(shard_results, :duration_us)),
      dispatcher: dispatcher_snapshot,
      send_calls: sum_field(shard_results, :send_calls),
      payload_events: sum_field(shard_results, :payload_events),
      completion_events: sum_field(shard_results, :completion_events),
      send_cancelled_events: sum_field(shard_results, :send_cancelled_events),
      orphan_completion_events: sum_field(shard_results, :orphan_completion_events),
      ignored_events: sum_field(shard_results, :ignored_events),
      unknown_events: sum_field(shard_results, :unknown_events),
      receive_calls: count_summary(map_field(shard_results, :receive_calls)),
      ready_drain_calls: count_summary(map_field(shard_results, :ready_drain_calls)),
      schedule_rounds: count_summary(map_field(shard_results, :schedule_rounds))
    })
  end

  defp local_sender_flow_partition_summary(
         implementation,
         shard_results,
         configured_shard_count,
         sink_start_duration_us,
         sink_await_duration_us
       ) do
    implementation
    |> implementation_summary()
    |> Map.merge(%{
      accepted: sum_field(shard_results, :accepted),
      completed: sum_field(shard_results, :completed),
      in_flight: sum_field(shard_results, :in_flight),
      configured_shard_count: configured_shard_count,
      active_shard_count: length(shard_results),
      streams_per_shard: count_summary(map_field(shard_results, :stream_count)),
      max_shard_in_flight: max_field(shard_results, :max_in_flight),
      max_shard_queue_depth: max_field(shard_results, :max_queue_depth),
      sink_start_duration_us: sink_start_duration_us,
      sink_await_duration_us: sink_await_duration_us,
      shard_duration_us: count_summary(map_field(shard_results, :duration_us)),
      dispatcher: %{
        mode: "gen_stage_partition",
        routed_events: sum_field(shard_results, :payload_events),
        unknown_stream_events: sum_field(shard_results, :orphan_completion_events)
      },
      send_calls: sum_field(shard_results, :send_calls),
      payload_events: sum_field(shard_results, :payload_events),
      source_eof_events: sum_field(shard_results, :source_eof_events),
      completion_events: sum_field(shard_results, :completion_events),
      send_cancelled_events: sum_field(shard_results, :send_cancelled_events),
      orphan_completion_events: sum_field(shard_results, :orphan_completion_events),
      ignored_events: sum_field(shard_results, :ignored_events),
      unknown_events: sum_field(shard_results, :unknown_events),
      receive_calls: count_summary(map_field(shard_results, :receive_calls)),
      ready_drain_calls: count_summary(map_field(shard_results, :ready_drain_calls)),
      schedule_rounds: count_summary(map_field(shard_results, :schedule_rounds)),
      upstream_closed_count: Enum.count(shard_results, & &1.upstream_closed?),
      producer_cancel_reasons: unique_flat_map(shard_results, :producer_cancel_reasons)
    })
  end

  defp implementation_summary(name) do
    StreamImplementations.metadata(name)
    |> Map.put(:implementation, name)
  end

  defp timed(fun) when is_function(fun, 0) do
    started_at_us = monotonic_us()
    result = fun.()
    {monotonic_us() - started_at_us, result}
  end

  defp pacer_summary(pacer) do
    %{
      count: pacer.count,
      emitted_count: pacer.emitted_count,
      rate_per_second: pacer.rate_per_second,
      tick_ms: pacer.tick_ms,
      max_burst: pacer.max_burst,
      tick_count: pacer.tick_count,
      capped_tick_count: pacer.capped_tick_count,
      empty_tick_count: pacer.empty_tick_count,
      tool_limited_tick_count: pacer.tool_limited_tick_count
    }
  end

  defp count_summary(values) do
    values = Enum.filter(values, &is_number/1)
    count = length(values)

    %{
      count: count,
      min: min_value(values),
      avg: average_value(values, count),
      max: max_value(values),
      p95: percentile_value(values, 0.95),
      total: Enum.sum(values)
    }
  end

  defp min_value([]), do: nil
  defp min_value(values), do: Enum.min(values)

  defp max_value([]), do: nil
  defp max_value(values), do: Enum.max(values)

  defp average_value(_values, 0), do: nil
  defp average_value(values, count), do: Enum.sum(values) / count

  defp percentile_value([], _percentile), do: nil

  defp percentile_value(values, percentile) do
    sorted = Enum.sort(values)
    index = ceil(length(sorted) * percentile) - 1
    Enum.at(sorted, max(index, 0))
  end

  defp sum_field(values, field) do
    values
    |> map_field(field)
    |> Enum.sum()
  end

  defp max_field(values, field) do
    values
    |> map_field(field)
    |> max_value()
  end

  defp map_field(values, field), do: Enum.map(values, &Map.fetch!(&1, field))

  defp unique_flat_map(values, field) do
    values
    |> map_field(field)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp encode_atom(nil), do: nil
  defp encode_atom(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp encode_atom(value), do: value

  defp maybe_run_receipt(%{evidence_enabled?: true} = input, result, started_at, cleanup) do
    receipt =
      RunReceipt.new!(
        id: input.receipt_id,
        target: input.target,
        scenario: @profile_name,
        input: producer_name(input.producer),
        implementation: input.implementation,
        expected: expected_evidence(input),
        match: evidence_match(input),
        metadata: receipt_metadata(input, result),
        started_at: started_at,
        finished_at: DateTime.utc_now()
      )

    %TimedRun{receipt: receipt, cleanup: cleanup}
  end

  defp maybe_run_receipt(_input, result, _started_at, _cleanup), do: result

  defp receipt_timestamp(%{evidence_enabled?: true}), do: DateTime.utc_now()
  defp receipt_timestamp(_input), do: nil

  defp evidence_enabled?(%{evidence_enabled?: true}), do: true
  defp evidence_enabled?(_input), do: false

  defp maybe_evidence_close_grace(%{evidence_enabled?: true, evidence_close_grace_ms: ms})
       when ms > 0 do
    Process.sleep(ms)
  end

  defp maybe_evidence_close_grace(_input), do: :ok

  defp receipt_id(input) do
    suffix = System.unique_integer([:positive])
    "#{producer_name(input.producer)}-#{suffix}"
  end

  defp expected_evidence(input) do
    Map.merge(@zero_evidence, %{
      uni_streams_accepted: input.stream_count,
      streams_completed: input.stream_count,
      stream_bytes_received: input.stream_count * input.payload_count * input.payload_size
    })
  end

  defp evidence_match(%{target: :quicprobe, quicprobe_after_run_sequence: sequence} = input) do
    %{after_run_sequence: sequence}
    |> maybe_put_quicprobe_experiment_lease_token(Map.get(input, :quicprobe_experiment_lease))
  end

  defp evidence_match(_input), do: %{}

  defp maybe_put_quicprobe_experiment_lease_token(match, %{"token" => token})
       when is_binary(token),
       do: Map.put(match, :experiment_lease_token, token)

  defp maybe_put_quicprobe_experiment_lease_token(match, %{token: token})
       when is_binary(token),
       do: Map.put(match, :experiment_lease_token, token)

  defp maybe_put_quicprobe_experiment_lease_token(match, _lease), do: match

  defp receipt_metadata(input, result) do
    %{
      target: input.target,
      profile: @profile_name,
      host: Map.get(input, :host),
      quic_port: Map.get(input, :quic_port),
      iperf_port: Map.get(input, :iperf_port),
      ca: Map.get(input, :ca),
      servername: Map.get(input, :servername),
      alpn: Map.get(input, :alpn),
      git_sha: Map.get(input, :git_sha),
      iperf3_preflight: Map.get(input, :iperf3_preflight, []),
      tailscale_path_mode: Map.get(input, :tailscale_path_mode),
      server_stats_path: Map.get(input, :server_stats_path),
      producer: producer_name(input.producer),
      stream_count: input.stream_count,
      payload_count: input.payload_count,
      payload_size: input.payload_size,
      stream_send_window: input.stream_send_window,
      sender_shard_count: input.sender_shard_count,
      flow_stages: input.flow_stages,
      evidence_close_grace_ms: Map.get(input, :evidence_close_grace_ms),
      quicprobe_evidence_url: Map.get(input, :quicprobe_evidence_url),
      quicprobe_evidence_path: Map.get(input, :quicprobe_evidence_path),
      quicprobe_experiment_lease: public_quicprobe_experiment_lease(input),
      local_sender: result,
      quicprobe_after_run_sequence: Map.get(input, :quicprobe_after_run_sequence)
    }
  end

  defp public_quicprobe_experiment_lease(%{quicprobe_experiment_lease: lease})
       when is_map(lease) do
    Map.take(lease, ["token", "owner", "acquired_at", "expires_at", "ttl_ms", "metadata"])
  end

  defp public_quicprobe_experiment_lease(_input), do: nil

  defp producer_name(:flow_generated), do: "flow-generated"
  defp producer_name(:flow_prebuilt_list), do: "flow-prebuilt-list"

  defp events(%{producer: :flow_prebuilt_list} = input, streams, payload) do
    StreamSender.events_for(
      streams: streams,
      payload: payload,
      payload_count: input.payload_count
    )
  end

  defp events(%{producer: :flow_generated}, _streams, _payload), do: nil

  defp stream_events(input, streams, payload) do
    events(input, streams, payload) ||
      StreamSender.events_for(
        streams: streams,
        payload: payload,
        payload_count: input.payload_count
      )
  end

  defp partition_stream_events(input, streams, payload, partition_count) do
    Elixir.Stream.concat(
      stream_events(input, streams, payload),
      source_eof_events(partition_count)
    )
  end

  defp source_eof_events(partition_count) do
    Enum.map(0..(partition_count - 1), fn partition ->
      %{control: :source_eof, partition: partition}
    end)
  end

  defp payload(input), do: :binary.copy(<<0>>, input.payload_size)

  defp completion_list(completions),
    do: Enum.map(completions, fn {stream, count} -> {stream, count} end)

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp default_sender_shard_count(opts) do
    stream_count = positive_integer(opts, :stream_count, 32)
    max(min(stream_count, System.schedulers_online()), 1)
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)

  defp help do
    """
    Usage:
      mix run bench/stream_clients.exs -- [options]

    Target:
      --target NAME                fake or quicprobe (default: fake)
      --host HOST                  quicprobe host for --target quicprobe (default: 127.0.0.1)
      --quic-port PORT             quicprobe UDP port (default: 4433)
      --iperf-port PORT            iperf3 TCP/UDP baseline port metadata (default: 5201)
      --ca PATH                    trusted CA PEM for --target quicprobe
      --servername NAME            TLS server name (default: localhost)
      --alpn VALUE                 QUIC ALPN (default: moqx-test)
      --connect-timeout-ms N       QUIC connect timeout (default: 5000)

    Workload:
      --stream-count N             number of unidirectional streams (default: 32)
      --payload-count N            payload writes per stream (default: 1000)
      --payload-size BYTES         payload bytes per write (default: 1180)
      --stream-send-window N       per-stream in-flight send window (default: 16)
      --sender-shard-count N       sender_shards worker count (default: min(streams, schedulers))
      --flow-stages N              Flow source stages; ordered stream workloads require 1
      --max-burst N                max sends emitted by one StreamSink tick (default: 64)
      --max-queue-depth N          Flow-to-sink queue bound (default: 256)
      --min-demand N               Flow min demand (default: max_burst - 1)
      --max-demand N               Flow max demand (default: max_burst)
      --idle-retries N             empty-drain retries before returning (default: 1000)
      --event-batch-size N         ready completion drain limit (default: 1024)
      --timeout-ms N               per invocation timeout (default: 15000)

    Matrix:
      --input NAME                 repeatable; flow-generated or flow-prebuilt-list
      --implementation NAME        repeatable; #{StreamImplementations.help_names()}

    Stream implementations:
    #{StreamImplementations.help_details()}

    Benchee:
      --benchee-warmup SECONDS     default: 1.0
      --benchee-time SECONDS       default: 3.0
      --benchee-memory-time SEC    default: 0.0
      --benchee-reduction-time SEC default: 0.0
      --benchee-parallel N         default: 1
      --save PATH                  save Benchee suite for later comparison

    Evidence:
      --evidence-output PATH        write post-run delivery evidence JSONL
      --evidence-timeout-ms N       evidence collection timeout (default: 5000)
      --evidence-poll-ms N          evidence polling interval (default: 50)
      --evidence-close-grace-ms N   post-send grace before close; quicprobe default: 25
      --quicprobe-evidence-url URL  quicprobe evidence API URL (default: http://<host>:55434)
      --quicprobe-evidence-port N   default evidence API port (default: 55434)
      --quicprobe-evidence-path P   local quicprobe server JSONL path fallback
                                    quicprobe targets acquire an exclusive experiment lease;
                                    do not run parallel experiments against one quicprobe

    Host and BEAM samples (out-of-band sampler, ADR-0009):
      --host-sample-ms N            sampling interval in ms (default: 0 = disabled)
      --host-samples-output PATH    write host/BEAM saturation samples JSONL sidecar
                                    samples are taken in a dedicated sampler process,
                                    never inside the timed function or a telemetry handler;
                                    requires --benchee-parallel 1

    Run metadata:
      --git-sha SHA                  git SHA metadata (default: current HEAD)
      --iperf-preflight-summary PATH repeatable iperf3 JSON summary sidecar
      --tailscale-path-mode MODE     optional Tailscale path mode, e.g. direct or relay
      --server-stats-path PATH       optional server stats/evidence path metadata

    Example:
      mix run bench/stream_clients.exs -- --stream-count 32 --payload-count 1000 --stream-send-window 16 --benchee-time 3
    """
  end

  def main(argv \\ System.argv()) do
    options =
      argv
      |> parse_cli!()
      |> prepare_run!()

    try do
      options = start_host_sampler(options)

      try do
        apply(Benchee, :run, [jobs(options), benchee_config(options)])

        write_evidence!(options)
      after
        stop_host_sampler(options)
      end
    after
      cleanup_run(options)
    end
  end
end

unless Mix.env() == :test do
  MOQXProbe.Bench.StreamClients.main()
end
