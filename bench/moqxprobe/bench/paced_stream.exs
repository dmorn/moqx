# Open-loop paced stream sender (detect-only).
#
# This is the OPEN-LOOP measurement mode of ADR-0009
# (docs/adr/0009-layered-benchmark-evidence-contract.md). It is deliberately a
# STANDALONE script, NOT a Benchee job: Benchee is closed-loop (it calls a job,
# waits for it to return, then calls it again, measuring service time). This
# script instead offers payload intents on a fixed WALL-CLOCK schedule
# regardless of whether the transport accepted the previous offers. It does not
# throttle the offered rate to match what the transport admits — that is the
# whole point. Backpressure shows up as backlog and tick lag, not as a slower
# offered rate.
#
# It reuses the transport client setup, delivery-evidence wiring
# (EvidenceCollector / --evidence-output), and the out-of-band HostSampler from
# the closed-loop bench/stream_clients.exs, but the two modes are kept separate:
# do not entangle Benchee timing with the paced schedule.
#
# Detect-only for coordinated omission: when the sender falls behind its
# schedule (backlog past a threshold or sustained tick lag), it sets a
# coordinated_omission flag, meaning the offered rate could not be sustained and
# any naive latency reading would omit the stalls. It does NOT compute a
# corrected latency histogram — that is deferred to issue 56.

defmodule MOQXProbe.Bench.PacedStream do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.Transport.Conn.Stream.Info
  alias MOQX.Transport.Quicer
  alias MOQXProbe.Benchee.Adapters
  alias MOQXProbe.Benchee.EvidenceCollector
  alias MOQXProbe.Benchee.RunManifest
  alias MOQXProbe.Benchee.RunMetadata
  alias MOQXProbe.Benchee.RunReceipt
  alias MOQXProbe.HostSampler
  alias MOQXProbe.OpenLoop.Accounting
  alias MOQXProbe.OpenLoop.Pacer

  import MOQXProbe.BenchCLI,
    only: [
      drop_mix_separator: 1,
      positive_integer: 3,
      non_negative_integer: 3,
      cli_key: 1,
      url_host: 1,
      manifest_args: 1
    ]

  @schema_version "moqxprobe-paced-v1"
  @profile_name "draft14_object_stream"
  @target_names ["fake", "quicprobe"]
  @rate_modes ["payload-events", "bytes"]
  @tiers ["fake", "loopback_quic", "remote_quic_no_wire", "remote_quic_with_wire"]
  @quicprobe_experiment_lease_ttl_ms 30 * 60 * 1000

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
    payload_size: :integer,
    offered_rate: :integer,
    rate_mode: :string,
    tick_ms: :integer,
    duration_ms: :integer,
    backlog_threshold: :integer,
    sustained_lag_ms: :integer,
    sustained_lag_ticks: :integer,
    drain_ms: :integer,
    tier: :string,
    paced_output: :string,
    manifest_output: :string,
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
    tailscale_path_mode: :string,
    server_stats_path: :string
  ]
  @aliases [h: :help]

  defmodule FakeTransport do
    @moduledoc false

    @behaviour Transport

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
    def connect(_host, _port, _opts, _timeout), do: {:ok, {:fake_conn, make_ref()}}

    @impl true
    def open_stream({:fake_conn, conn_ref}, opts) do
      direction = option(opts, :direction, :unidirectional)
      {:ok, {:fake_stream, conn_ref, make_ref(), direction}}
    end

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream({:fake_stream, _conn_ref, _stream_ref, _direction} = stream, _data, _opts) do
      # Fake-only: each send self-posts a completion that is drained out of band
      # after the send window, so the caller mailbox holds one message per
      # offered intent during the run. This is bounded by offered_rate * duration
      # and is acceptable for fake calibration; real transports do not buffer
      # completions this way.
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
    def stream_info({:fake_stream, _conn_ref, stream_ref, direction}, local_role, initiator) do
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

  def main(argv \\ System.argv()) do
    options = argv |> parse_cli!() |> prepare_run!()

    try do
      options = start_host_sampler(options)

      try do
        run(options)
      after
        stop_host_sampler(options)
      end
    after
      cleanup_run(options)
    end
  end

  # --- run ------------------------------------------------------------------

  defp run(options) do
    {ctx, streams, connection} = setup_streams(options)
    started_at = DateTime.utc_now()

    {accounting, tick_rows} = paced_send_window(ctx, streams, options)

    # Settle the transport out of band: drain any send completions still in
    # flight after the schedule window so accepted reconciles with offered
    # modulo tail drain. This is NOT part of the schedule and never throttles it.
    accounting = settle(ctx, accounting, options)

    close_connection(ctx, connection, options)

    summary = Accounting.summary(accounting)
    write_paced_sidecar!(options, tick_rows, summary)
    print_summary(options, summary)

    maybe_collect_delivery_evidence(options, accounting, started_at)
    write_manifest!(options)
  end

  # The schedule loop. It advances the pacer on wall-clock ticks and offers the
  # full due_count each tick by attempting one transport send per intent,
  # round-robin across the opened streams. It does NOT wait for send completion
  # before advancing the schedule. Accepted = transport admitted the send;
  # send-admission errors are counted, never retried inside the schedule.
  defp paced_send_window(ctx, streams, options) do
    payload = :binary.copy(<<0>>, options.payload_size)
    stream_vec = List.to_tuple(streams)

    pacer =
      Pacer.new!(
        mode: options.rate_mode,
        offered_rate: options.offered_rate,
        payload_size: options.payload_size,
        tick_ms: options.tick_ms,
        duration_ms: options.duration_ms,
        started_at_ms: monotonic_ms()
      )

    accounting =
      Accounting.new!(
        backlog_threshold: options.backlog_threshold,
        sustained_lag_ms: options.sustained_lag_ms,
        sustained_lag_ticks: options.sustained_lag_ticks
      )

    loop_state = %{
      ctx: ctx,
      payload: payload,
      stream_vec: stream_vec,
      cursor: 0
    }

    {accounting, tick_rows} = schedule_loop(pacer, accounting, loop_state, [])

    {accounting, Enum.reverse(tick_rows)}
  end

  defp schedule_loop(pacer, accounting, loop_state, tick_rows) do
    now = monotonic_ms()

    if Pacer.schedule_complete?(pacer, now) do
      {accounting, tick_rows}
    else
      sleep_until(Pacer.next_deadline_ms(pacer))
      now = monotonic_ms()
      {tick, pacer} = Pacer.tick(pacer, now)
      {accepted, errors, loop_state} = offer_intents(loop_state, tick.due_count)

      {tick_row, accounting} =
        Accounting.record_tick(accounting, tick, accepted: accepted, errors: errors)

      schedule_loop(pacer, accounting, loop_state, [tick_row | tick_rows])
    end
  end

  # Offer `due_count` payload intents by attempting one transport send each,
  # round-robin across streams. Returns {accepted, errors, loop_state}. We do
  # not block on send completion: send_stream returns as soon as the transport
  # admits (or rejects) the write.
  defp offer_intents(loop_state, 0), do: {0, 0, loop_state}

  defp offer_intents(loop_state, due_count) do
    Enum.reduce(1..due_count, {0, 0, loop_state}, fn _i, {accepted, errors, loop_state} ->
      stream = elem(loop_state.stream_vec, loop_state.cursor)
      next_cursor = rem(loop_state.cursor + 1, tuple_size(loop_state.stream_vec))
      loop_state = %{loop_state | cursor: next_cursor}

      case Transport.send_stream(loop_state.ctx, stream, loop_state.payload, []) do
        {:ok, _send, ctx} ->
          {accepted + 1, errors, %{loop_state | ctx: ctx}}

        {:error, _reason, ctx} ->
          {accepted, errors + 1, %{loop_state | ctx: ctx}}
      end
    end)
  end

  # Out-of-band settlement: drains the send completions/cancellations the
  # transport reports after the schedule window. These do not change the offered
  # or accepted totals (every send was already counted as accepted at admission
  # time), so they are recorded through Accounting.record_settlement/2 as
  # explicit tail-drain counters rather than silently discarded. This makes the
  # tail drain visible in the summary, which is what the receiver-byte
  # reconciliation (accepted bytes <= received bytes) relies on. It is bounded by
  # --drain-ms and never throttles the schedule.
  defp settle(ctx, accounting, options) do
    {completed, cancelled} = drain_completions(ctx, monotonic_ms() + options.drain_ms, 0, 0)
    Accounting.record_settlement(accounting, completed: completed, cancelled: cancelled)
  end

  defp drain_completions(ctx, deadline_ms, completed, cancelled) do
    if monotonic_ms() >= deadline_ms do
      {completed, cancelled}
    else
      case Transport.receive_event(ctx, 0) do
        {:timeout, _ctx} ->
          sleep_ms(1)
          drain_completions(ctx, deadline_ms, completed, cancelled)

        {:ok, {:stream_event, _stream, :send_completed, _metadata}, _ctx} ->
          drain_completions(ctx, deadline_ms, completed + 1, cancelled)

        {:ok, {:stream_event, _stream, :send_cancelled, _metadata}, _ctx} ->
          drain_completions(ctx, deadline_ms, completed, cancelled + 1)

        {_tag, _event, _ctx} ->
          drain_completions(ctx, deadline_ms, completed, cancelled)
      end
    end
  end

  # --- delivery evidence (out of band, after the paced send window) ----------

  defp maybe_collect_delivery_evidence(%{evidence: %{enabled?: false}}, _accounting, _started_at) do
    :ok
  end

  defp maybe_collect_delivery_evidence(%{evidence: evidence} = options, accounting, started_at) do
    receipt =
      RunReceipt.new!(
        id: evidence.run_id,
        target: options.target,
        scenario: @profile_name,
        input: "open_loop_paced",
        implementation: "open_loop_paced",
        expected: expected_evidence(options, accounting),
        match: evidence_match(options),
        metadata: receipt_metadata(options, accounting),
        started_at: started_at,
        finished_at: DateTime.utc_now()
      )

    {adapter, adapter_opts} = evidence_adapter(options)
    _ = EvidenceCollector.collect(evidence.collector, adapter, receipt, adapter_opts)
    write_delivery_evidence!(options)
  end

  defp evidence_adapter(%{target: :quicprobe, evidence: evidence}) do
    {Adapters.Quicprobe, quicprobe_evidence_opts(evidence)}
  end

  defp expected_evidence(%{target: :quicprobe} = options, accounting) do
    # Reconcile accepted bytes with receiver bytes modulo tail drain. This is an
    # open-loop run that deliberately offers faster than the transport can
    # deliver, so at window close some admitted sends are still in flight: the
    # receiver keeps draining bytes after the sender's schedule ends. The check
    # is therefore a LOWER BOUND, not exact equality — the receiver must see at
    # least the accepted payload events (each payload_size bytes), and may see
    # more once the tail drains. Asserting exact equality would mark a legitimate
    # open-loop run :invalid. Open-loop runs do not assert FIN here because the
    # schedule, not a fixed payload-per-stream count, drives sends.
    %{
      uni_streams_accepted: options.stream_count,
      stream_bytes_received: {:at_least, accounting.accepted_total * options.payload_size},
      receiver_evidence_complete: true
    }
  end

  defp expected_evidence(_options, _accounting), do: %{}

  defp evidence_match(%{target: :quicprobe, evidence: evidence}) do
    %{after_run_sequence: evidence.after_run_sequence}
    |> maybe_put_lease_token(evidence.quicprobe_experiment_lease)
  end

  defp evidence_match(_options), do: %{}

  defp maybe_put_lease_token(match, %{"token" => token}) when is_binary(token),
    do: Map.put(match, :experiment_lease_token, token)

  defp maybe_put_lease_token(match, _lease), do: match

  defp write_delivery_evidence!(%{evidence: %{collector: collector, output: output}}) do
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

  # --- paced sidecar ---------------------------------------------------------

  defp write_paced_sidecar!(%{paced_output: nil}, _tick_rows, _summary), do: :ok

  defp write_paced_sidecar!(options, tick_rows, summary) do
    options.paced_output |> Path.dirname() |> File.mkdir_p!()

    rows = [paced_header(options) | tick_rows] ++ [summary]

    content = Enum.map_join(rows, "", fn row -> JSON.encode!(row) <> "\n" end)

    case File.write(options.paced_output, content) do
      :ok ->
        IO.puts("Paced sidecar: wrote #{options.paced_output} (#{length(tick_rows)} tick rows)")
        :ok

      {:error, reason} ->
        Mix.raise("failed to write paced sidecar #{options.paced_output}: #{inspect(reason)}")
    end
  end

  defp paced_header(options) do
    %{
      schema_version: @schema_version,
      record_type: "header",
      mode: "open_loop",
      tier: options.tier,
      target: options.target,
      rate_mode: Atom.to_string(options.rate_mode),
      offered_rate: options.offered_rate,
      offered_rate_unit: offered_rate_unit(options.rate_mode),
      tick_ms: options.tick_ms,
      duration_ms: options.duration_ms,
      stream_count: options.stream_count,
      payload_size: options.payload_size,
      backlog_threshold: options.backlog_threshold,
      sustained_lag_ms: options.sustained_lag_ms,
      sustained_lag_ticks: options.sustained_lag_ticks,
      git_sha: options.git_sha,
      host: options.host,
      quic_port: options.quic_port,
      tailscale_path_mode: options.tailscale_path_mode,
      coordinated_omission_corrected_latency: "deferred_to_issue_56"
    }
  end

  defp offered_rate_unit(:payload_events), do: "payload_events_per_second"
  defp offered_rate_unit(:bytes), do: "bytes_per_second"

  # --- run manifest (ADR-0009 experiment lifecycle) --------------------------

  # Opt-in/additive; no-op without --manifest-output. Records mode=open_loop
  # and references the sidecars this paced run actually produced, with explicit
  # nil for unproduced slots.
  defp write_manifest!(%{manifest: %{enabled?: false}}), do: :ok

  defp write_manifest!(%{manifest: manifest} = options) do
    inputs = %{
      run_id: manifest_run_id(options),
      created_at: DateTime.to_iso8601(DateTime.utc_now()),
      command: "mix run bench/paced_stream.exs",
      args: manifest.args,
      git_sha: options.git_sha,
      versions: RunMetadata.versions(),
      target_type: RunManifest.target_type(options.target, options.tier),
      mode: :open_loop,
      tier: String.to_atom(options.tier),
      target: manifest_target(options),
      client_implementation: "open_loop_paced",
      workload: manifest_workload(options),
      sidecars: manifest_sidecars(options),
      clock_source_notes: %{
        schedule: "System.monotonic_time/1 fixed wall-clock pacer",
        sampler: "System.monotonic_time/1 out-of-band sampler"
      }
    }

    case RunManifest.write(inputs, manifest.output) do
      :ok ->
        IO.puts("Run manifest: wrote #{manifest.output}")
        :ok

      {:error, reason} ->
        Mix.raise("failed to write run manifest #{manifest.output}: #{inspect(reason)}")
    end
  end

  defp manifest_run_id(%{evidence: %{enabled?: true, run_id: run_id}}), do: run_id
  defp manifest_run_id(_options), do: evidence_run_id()

  defp manifest_target(%{target: :fake}), do: nil

  defp manifest_target(options) do
    %{
      host: options.host,
      quic_port: options.quic_port,
      iperf_port: options.iperf_port,
      servername: options.servername,
      alpn: options.alpn
    }
  end

  defp manifest_workload(options) do
    %{
      profile: @profile_name,
      stream_count: options.stream_count,
      payload_size: options.payload_size,
      offered_rate: options.offered_rate,
      offered_rate_unit: offered_rate_unit(options.rate_mode),
      tick_ms: options.tick_ms,
      duration_ms: options.duration_ms
    }
  end

  defp manifest_sidecars(options) do
    %{
      paced: options.paced_output,
      delivery_evidence: produced_sidecar(options.evidence.enabled?, options.evidence.output),
      host_samples: produced_sidecar(options.host_samples.enabled?, options.host_samples.output)
    }
  end

  defp produced_sidecar(true, output), do: output
  defp produced_sidecar(_enabled, _output), do: nil

  defp print_summary(options, summary) do
    IO.puts(
      "open-loop paced run (#{options.target}, tier=#{options.tier}): " <>
        "offered=#{summary.offered_payload_events_total} " <>
        "accepted=#{summary.accepted_payload_events_sender_active_total} " <>
        "errors=#{summary.send_admission_error_count} " <>
        "drained_completions=#{summary.send_completions_drain_total} " <>
        "drained_cancellations=#{summary.send_cancellations_drain_total} " <>
        "backlog=#{summary.backlog_payload_events} " <>
        "max_backlog=#{summary.max_backlog_payload_events} " <>
        "max_tick_lag_ms=#{summary.max_tick_lag_ms} " <>
        "coordinated_omission=#{summary.coordinated_omission}"
    )

    if summary.coordinated_omission do
      IO.puts(
        "WARNING: coordinated omission detected (cause=#{summary.coordinated_omission_cause}). " <>
          "The offered rate could not be sustained; naive latency would omit the stalls. " <>
          "Corrected latency percentiles are deferred to issue 56."
      )
    end
  end

  # --- transport setup (reused from stream_clients.exs) ----------------------

  defp setup_streams(%{target: :fake} = options) do
    {:ok, ctx} = Transport.new(FakeTransport, [])
    {:ok, connection, ctx} = Transport.connect(ctx, "localhost", 4433, [], 1_000)
    open_streams(ctx, connection, options)
  end

  defp setup_streams(%{target: :quicprobe} = options) do
    {:ok, ctx} = Transport.new(Quicer, [])

    {:ok, connection, ctx} =
      Transport.connect(
        ctx,
        options.host,
        options.quic_port,
        quicprobe_connect_opts(options),
        options.connect_timeout_ms
      )

    open_streams(ctx, connection, options)
  end

  defp open_streams(ctx, connection, options) do
    {streams, ctx} =
      Enum.reduce(1..options.stream_count, {[], ctx}, fn _index, {streams, ctx} ->
        {:ok, stream, ctx} = Transport.open_stream(ctx, connection, direction: :unidirectional)
        {[stream | streams], ctx}
      end)

    {ctx, Enum.reverse(streams), connection}
  end

  defp quicprobe_connect_opts(options) do
    [
      alpn: options.alpn,
      cacertfile: options.ca,
      verify: :verify_peer,
      server_name: options.servername,
      peer_bidi_stream_count: max(options.stream_count + 2, 10),
      peer_unidi_stream_count: max(options.stream_count + 2, 10)
    ]
  end

  defp close_connection(ctx, connection, options) do
    if options.evidence.close_grace_ms > 0, do: sleep_ms(options.evidence.close_grace_ms)

    case Transport.close_connection(ctx, connection, 0) do
      {:ok, _ctx} -> :ok
      {:error, _reason, _ctx} -> :ok
    end
  end

  # --- host sampler (out of band, reused from stream_clients.exs) ------------

  defp start_host_sampler(%{host_samples: %{enabled?: false}} = options), do: options

  defp start_host_sampler(%{host_samples: host_samples} = options) do
    {:ok, sampler} =
      HostSampler.start_link(
        interval_ms: host_samples.interval_ms,
        output: host_samples.output,
        roles: [{"paced_sender", self()}]
      )

    put_in(options, [:host_samples, :sampler], sampler)
  end

  defp stop_host_sampler(%{host_samples: %{sampler: sampler, output: output}})
       when is_pid(sampler) do
    :ok = HostSampler.stop(sampler)
    IO.puts("Host samples: wrote #{output}")
    :ok
  end

  defp stop_host_sampler(_options), do: :ok

  # --- run lifecycle ---------------------------------------------------------

  defp prepare_run!(options) do
    options = acquire_quicprobe_experiment_lease!(options)

    try do
      prepare_evidence!(options)
    rescue
      exception ->
        release_quicprobe_experiment_lease(options)
        reraise exception, __STACKTRACE__
    end
  end

  defp prepare_evidence!(%{evidence: %{enabled?: false}} = options), do: options

  defp prepare_evidence!(%{evidence: evidence} = options) do
    {:ok, collector} = EvidenceCollector.start(run_id: evidence.run_id)
    after_run_sequence = quicprobe_evidence_cursor(options)

    evidence = %{evidence | collector: collector, after_run_sequence: after_run_sequence}
    %{options | evidence: evidence}
  end

  defp cleanup_run(options) do
    if collector = get_in(options, [:evidence, :collector]) do
      EvidenceCollector.stop(collector)
    end
  after
    release_quicprobe_experiment_lease(options)
  end

  defp quicprobe_evidence_cursor(%{target: :quicprobe, evidence: evidence}) do
    case Adapters.Quicprobe.last_run_sequence(quicprobe_evidence_opts(evidence)) do
      {:ok, sequence} -> sequence
      {:error, _reason} -> 0
    end
  end

  defp quicprobe_evidence_cursor(_options), do: 0

  defp quicprobe_evidence_opts(evidence) do
    [
      url: evidence.quicprobe_evidence_url,
      path: evidence.quicprobe_evidence_path,
      timeout_ms: evidence.timeout_ms,
      poll_ms: evidence.poll_ms
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp acquire_quicprobe_experiment_lease!(%{target: :quicprobe, evidence: evidence} = options) do
    owner = "#{@profile_name}:open_loop:#{evidence.run_id}"

    opts = [
      url: evidence.quicprobe_evidence_url,
      owner: owner,
      ttl_ms: @quicprobe_experiment_lease_ttl_ms,
      timeout_ms: evidence.timeout_ms,
      metadata: %{
        "profile" => @profile_name,
        "mode" => "open_loop",
        "git_sha" => options.git_sha,
        "host" => options.host,
        "quic_port" => Integer.to_string(options.quic_port)
      }
    ]

    case Adapters.Quicprobe.acquire_experiment_lease(opts) do
      {:ok, lease} ->
        put_in(options, [:evidence, :quicprobe_experiment_lease], lease)

      {:error, {:quicprobe_experiment_lease_busy, response}} ->
        owner = get_in(response, ["lease", "owner"]) || "unknown owner"

        Mix.raise(
          "quicprobe target #{evidence.quicprobe_evidence_url} is already leased by #{owner}; " <>
            "parallel experiments against the same quicprobe corrupt evidence readings"
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
         target: :quicprobe,
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

  # --- metadata --------------------------------------------------------------

  defp receipt_metadata(options, accounting) do
    %{
      mode: "open_loop",
      tier: options.tier,
      target: options.target,
      profile: @profile_name,
      host: options.host,
      quic_port: options.quic_port,
      ca: options.ca,
      servername: options.servername,
      alpn: options.alpn,
      git_sha: options.git_sha,
      tailscale_path_mode: options.tailscale_path_mode,
      server_stats_path: options.server_stats_path,
      rate_mode: Atom.to_string(options.rate_mode),
      offered_rate: options.offered_rate,
      tick_ms: options.tick_ms,
      duration_ms: options.duration_ms,
      stream_count: options.stream_count,
      payload_size: options.payload_size,
      offered_payload_events_total: accounting.offered_total,
      accepted_payload_events_sender_active_total: accounting.accepted_total,
      send_admission_error_count: accounting.error_total,
      coordinated_omission: accounting.coordinated_omission?,
      paced_sidecar: options.paced_output
    }
  end

  # --- CLI -------------------------------------------------------------------

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
        opts
        |> base_options()
        |> put_evidence_options(opts)
        |> put_host_samples_options(opts)
        |> put_manifest_options(opts)
    end
  end

  # Run manifest (ADR-0009 experiment-lifecycle layer): opt-in via
  # --manifest-output. The script supplies the runtime values; the pure
  # RunManifest module only assembles and serializes them.
  defp put_manifest_options(options, opts) do
    output = Keyword.get(opts, :manifest_output)

    Map.put(options, :manifest, %{
      enabled?: is_binary(output),
      output: output,
      args: manifest_args(opts)
    })
  end

  defp base_options(opts) do
    %{
      target: target(opts),
      host: Keyword.get(opts, :host, "127.0.0.1"),
      quic_port: positive_integer(opts, :quic_port, 4433),
      iperf_port: positive_integer(opts, :iperf_port, 5201),
      ca: Keyword.get(opts, :ca),
      servername: Keyword.get(opts, :servername, "localhost"),
      alpn: Keyword.get(opts, :alpn, "moqx-test"),
      connect_timeout_ms: positive_integer(opts, :connect_timeout_ms, 5_000),
      stream_count: positive_integer(opts, :stream_count, 32),
      payload_size: positive_integer(opts, :payload_size, 1_180),
      offered_rate: positive_integer(opts, :offered_rate, 32_000),
      rate_mode: rate_mode(opts),
      tick_ms: positive_integer(opts, :tick_ms, 1),
      duration_ms: positive_integer(opts, :duration_ms, 3_000),
      backlog_threshold: positive_integer(opts, :backlog_threshold, 4_096),
      sustained_lag_ms: non_negative_integer(opts, :sustained_lag_ms, 5),
      sustained_lag_ticks: positive_integer(opts, :sustained_lag_ticks, 10),
      drain_ms: non_negative_integer(opts, :drain_ms, 500),
      tier: tier(opts, target(opts)),
      paced_output: Keyword.get(opts, :paced_output),
      git_sha: Keyword.get(opts, :git_sha, RunMetadata.git_sha()),
      tailscale_path_mode: Keyword.get(opts, :tailscale_path_mode),
      server_stats_path: Keyword.get(opts, :server_stats_path)
    }
    |> validate_target!()
  end

  defp put_evidence_options(options, opts) do
    output = Keyword.get(opts, :evidence_output)
    enabled? = is_binary(output)
    quicprobe_evidence_url = quicprobe_evidence_url(options, opts)

    Map.put(options, :evidence, %{
      enabled?: enabled?,
      output: output,
      timeout_ms: positive_integer(opts, :evidence_timeout_ms, 5_000),
      poll_ms: positive_integer(opts, :evidence_poll_ms, 50),
      close_grace_ms:
        non_negative_integer(
          opts,
          :evidence_close_grace_ms,
          default_close_grace_ms(options.target)
        ),
      quicprobe_evidence_url: quicprobe_evidence_url,
      quicprobe_evidence_path: Keyword.get(opts, :quicprobe_evidence_path),
      quicprobe_experiment_lease: nil,
      after_run_sequence: 0,
      run_id: evidence_run_id(),
      collector: nil
    })
  end

  defp put_host_samples_options(options, opts) do
    interval_ms = non_negative_integer(opts, :host_sample_ms, 0)
    output = Keyword.get(opts, :host_samples_output)
    enabled? = interval_ms > 0 and is_binary(output)

    if interval_ms > 0 and not is_binary(output) do
      Mix.raise("--host-sample-ms requires --host-samples-output PATH")
    end

    Map.put(options, :host_samples, %{
      enabled?: enabled?,
      interval_ms: interval_ms,
      output: output,
      sampler: nil
    })
  end

  defp target(opts) do
    case Keyword.get(opts, :target, "fake") do
      name when name in @target_names -> String.to_atom(name)
      name -> Mix.raise("--target must be one of #{Enum.join(@target_names, ", ")}; got #{name}")
    end
  end

  defp rate_mode(opts) do
    case Keyword.get(opts, :rate_mode, "payload-events") do
      "payload-events" -> :payload_events
      "bytes" -> :bytes
      name -> Mix.raise("--rate-mode must be one of #{Enum.join(@rate_modes, ", ")}; got #{name}")
    end
  end

  # Default the evidence tier from the target (RunManifest.default_tier/1) so a
  # fake-target paced run is not silently overclaimed as loopback_quic
  # (ADR-0009: `fake` is process-model only, with no QUIC/network claim).
  defp tier(opts, target) do
    case Keyword.get(opts, :tier, RunManifest.default_tier(target)) do
      name when name in @tiers -> name
      name -> Mix.raise("--tier must be one of #{Enum.join(@tiers, ", ")}; got #{name}")
    end
  end

  defp validate_target!(%{target: :quicprobe, ca: nil}) do
    Mix.raise("--ca is required when --target quicprobe")
  end

  defp validate_target!(options), do: options

  defp quicprobe_evidence_url(%{target: :quicprobe, host: host}, opts) do
    if Keyword.has_key?(opts, :quicprobe_evidence_url) do
      Keyword.fetch!(opts, :quicprobe_evidence_url)
    else
      "http://#{url_host(host)}:#{positive_integer(opts, :quicprobe_evidence_port, 55_434)}"
    end
  end

  defp quicprobe_evidence_url(_options, opts), do: Keyword.get(opts, :quicprobe_evidence_url)

  defp default_close_grace_ms(:quicprobe), do: 25
  defp default_close_grace_ms(_target), do: 0

  defp evidence_run_id do
    iso = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace("Z", "")
    "paced-#{iso}-#{System.unique_integer([:positive])}"
  end

  # --- time helpers ----------------------------------------------------------

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp sleep_until(deadline_ms) do
    remaining = deadline_ms - monotonic_ms()
    if remaining > 0, do: sleep_ms(remaining), else: :ok
  end

  defp sleep_ms(ms) when ms > 0, do: Process.sleep(ms)
  defp sleep_ms(_ms), do: :ok

  defp help do
    """
    Usage:
      mix run bench/paced_stream.exs -- [options]

    Open-loop paced stream sender (ADR-0009). Offers payload intents on a fixed
    wall-clock schedule regardless of completion; detects coordinated omission.
    This is NOT a Benchee job and is NOT comparable to closed-loop ips numbers.

    Target:
      --target NAME                fake or quicprobe (default: fake)
      --host HOST                  quicprobe host (default: 127.0.0.1)
      --quic-port PORT             quicprobe UDP port (default: 4433)
      --ca PATH                    trusted CA PEM for --target quicprobe
      --servername NAME            TLS server name (default: localhost)
      --alpn VALUE                 QUIC ALPN (default: moqx-test)
      --connect-timeout-ms N       QUIC connect timeout (default: 5000)

    Schedule (open loop):
      --offered-rate N             schedule rate; payload events/sec, or bytes/sec
                                   in --rate-mode bytes (default: 32000)
      --rate-mode MODE             payload-events or bytes (default: payload-events)
      --tick-ms N                  wall-clock tick interval (default: 1)
      --duration-ms N              schedule window length (default: 3000)
      --stream-count N             unidirectional streams to spread over (default: 32)
      --payload-size BYTES         bytes per payload intent (default: 1180)
      --drain-ms N                 post-window settle/drain budget (default: 500)

    Coordinated-omission detection (detect only; correction deferred to issue 56):
      --backlog-threshold N        trip flag when backlog exceeds N (default: 4096)
      --sustained-lag-ms N         a tick lags when tick_lag_ms exceeds N (default: 5)
      --sustained-lag-ticks N      trip flag after N consecutive lagging ticks (default: 10)

    Output:
      --paced-output PATH          write moqxprobe-paced-v1 JSONL sidecar
      --manifest-output PATH       write a moqxprobe-run-manifest-v1 manifest.json
                                   tying this open-loop run's artifacts together;
                                   records mode=open_loop and references the
                                   sidecars this run produced (explicit null otherwise)
      --tier TIER                  evidence tier: #{Enum.join(@tiers, ", ")} (default: fake for --target fake, else loopback_quic)

    Delivery evidence (out of band, after the paced window):
      --evidence-output PATH        write post-run delivery evidence JSONL
      --evidence-timeout-ms N       evidence collection timeout (default: 5000)
      --evidence-poll-ms N          evidence polling interval (default: 50)
      --evidence-close-grace-ms N   post-send grace before close; quicprobe default: 25
      --quicprobe-evidence-url URL  quicprobe evidence API URL (default: http://<host>:55434)
      --quicprobe-evidence-port N   default evidence API port (default: 55434)
      --quicprobe-evidence-path P   local quicprobe server JSONL path fallback

    Host and BEAM samples (out-of-band sampler, ADR-0009):
      --host-sample-ms N            sampling interval in ms (default: 0 = disabled)
      --host-samples-output PATH    write host/BEAM saturation samples JSONL sidecar

    Run metadata:
      --git-sha SHA                 git SHA metadata (default: current HEAD)
      --tailscale-path-mode MODE    optional Tailscale path mode (direct/relay)
      --server-stats-path PATH      optional server stats/evidence path metadata

    Example:
      mix run bench/paced_stream.exs -- --target fake --offered-rate 50000 \\
        --tick-ms 1 --duration-ms 3000 --paced-output results/paced.jsonl
    """
  end
end

unless Mix.env() == :test do
  MOQXProbe.Bench.PacedStream.main()
end
