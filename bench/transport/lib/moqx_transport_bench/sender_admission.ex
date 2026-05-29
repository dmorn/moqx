defmodule MOQX.TransportBench.SenderAdmission do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.Transport.Profile
  alias MOQX.Transport.Quicer
  alias MOQX.TransportBench.BuildInfo

  @default_script "moqx-transport-bench sender-admission"
  @script_version "v1"
  @schema_version "sender-admission-v1"
  @default_cert_dir ".tmp/transport-bench-certs"
  @default_datagram_size 1180
  @modes ~w(moqx quicer)
  @schedules ~w(burst paced)

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

  def measure_admissions(send_fun, payload, count, burst_size)
      when is_function(send_fun, 1) and is_binary(payload) and is_integer(count) and count >= 0 and
             is_integer(burst_size) and burst_size > 0 do
    started_at = monotonic_us()

    result =
      measure_bursts(send_fun, payload, count, burst_size, %{
        accepted: 0,
        errors: 0,
        error_reasons: %{},
        burst_durations_us: [],
        burst_counts: [],
        per_datagram_us: []
      })

    Map.put(result, :duration_us, monotonic_us() - started_at)
  end

  defp parse(argv, script) do
    argv = strip_mix_separator(argv)

    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          mode: :keep,
          profile: :string,
          host: :string,
          datagram_size: :integer,
          datagram_count: :integer,
          warmup_count: :integer,
          schedule: :string,
          tick_ms: :integer,
          burst_size: :integer,
          target_rate: :integer,
          repetitions: :integer,
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
         {:ok, modes} <- parse_modes(Keyword.get_values(opts, :mode)),
         {:ok, certs} <- cert_config(opts),
         {:ok, datagram_size} <- positive_integer(opts, :datagram_size, @default_datagram_size),
         {:ok, datagram_count} <- positive_integer(opts, :datagram_count, 96_000),
         {:ok, warmup_count} <- non_negative_integer(opts, :warmup_count, 1_024),
         {:ok, schedule} <- parse_schedule(Keyword.get(opts, :schedule, "burst")),
         {:ok, tick_ms} <- positive_integer(opts, :tick_ms, 1),
         {:ok, burst_size} <- positive_integer(opts, :burst_size, 32),
         {:ok, target_rate} <- positive_integer(opts, :target_rate, 32_000),
         {:ok, repetitions} <- positive_integer(opts, :repetitions, 1),
         {:ok, timeout_ms} <- positive_integer(opts, :timeout_ms, 5_000),
         :ok <- validate_profile_datagrams(profile) do
      {:ok,
       %{
         argv: argv,
         script: script,
         command: command_string(script, argv),
         profile: profile,
         modes: modes,
         host: Keyword.get(opts, :host, "127.0.0.1"),
         datagram_size: datagram_size,
         datagram_count: datagram_count,
         warmup_count: warmup_count,
         schedule: schedule,
         tick_ms: tick_ms,
         burst_size: burst_size,
         target_rate: target_rate,
         repetitions: repetitions,
         timeout_ms: timeout_ms,
         certs: certs,
         run_id: opts[:run_id] || default_run_id(),
         output: opts[:output],
         notes: opts[:notes]
       }}
    end
  end

  defp parse_profile("draft_14"), do: {:ok, :draft_14}
  defp parse_profile(profile), do: {:error, "Unknown --profile #{inspect(profile)}."}

  defp parse_modes([]), do: {:ok, @modes}

  defp parse_modes(modes) do
    unknown = Enum.reject(modes, &(&1 in @modes))

    if unknown == [] do
      {:ok, modes}
    else
      {:error, "Unknown --mode #{Enum.join(unknown, ", ")}. Expected moqx or quicer."}
    end
  end

  defp parse_schedule(schedule) when schedule in @schedules, do: {:ok, schedule}

  defp parse_schedule(schedule) do
    {:error, "Unknown --schedule #{inspect(schedule)}. Expected burst or paced."}
  end

  defp validate_profile_datagrams(%{capabilities: %{datagrams: true}}), do: :ok

  defp validate_profile_datagrams(_profile),
    do: {:error, "sender-admission requires DATAGRAM support."}

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

  defp run(config) do
    with :ok <- ensure_certs(config.certs),
         {:ok, _apps} <- Application.ensure_all_started(:quicer),
         {:ok, records} <- run_modes(config) do
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

  defp run_modes(config) do
    config.modes
    |> Enum.flat_map(fn mode -> Enum.map(1..config.repetitions, &{mode, &1}) end)
    |> Enum.reduce_while([], fn {mode, repetition}, records ->
      case run_mode_repetition(config, mode, repetition) do
        {:ok, record} -> {:cont, [record | records]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      records -> {:ok, Enum.reverse(records)}
    end
  end

  defp run_mode_repetition(config, mode, repetition) do
    run_started_at = timestamp()

    with_pair(config, fn pair ->
      payload = :binary.copy(<<0>>, config.datagram_size)
      send_fun = send_fun(mode, pair)

      warmup_result =
        measure_admissions(send_fun, payload, config.warmup_count, config.burst_size)

      _ctx = flush_transport_events(pair.ctx)

      measurement =
        measure_configured_admissions(config, send_fun, payload)

      run_finished_at = timestamp()

      {:ok,
       build_record(%{
         config: config,
         mode: mode,
         repetition: repetition,
         pair: pair,
         warmup_result: warmup_result,
         measurement: measurement,
         run_started_at: run_started_at,
         run_finished_at: run_finished_at
       })}
    end)
  end

  defp measure_configured_admissions(%{schedule: "burst"} = config, send_fun, payload) do
    send_fun
    |> measure_admissions(payload, config.datagram_count, config.burst_size)
    |> Map.merge(%{
      schedule: "burst",
      tick_lags_ms: [],
      tick_due_counts: [],
      tick_send_counts: [],
      tick_count: nil,
      empty_tick_count: nil,
      capped_tick_count: nil,
      max_due_datagrams: nil
    })
  end

  defp measure_configured_admissions(%{schedule: "paced"} = config, send_fun, payload) do
    send_fun
    |> measure_paced_admissions(
      payload,
      config.datagram_count,
      config.burst_size,
      config.target_rate,
      config.tick_ms
    )
    |> Map.put(:schedule, "paced")
  end

  defp send_fun("moqx", pair) do
    fn payload ->
      Transport.send_datagram(pair.ctx, pair.client, payload)
    end
  end

  defp send_fun("quicer", pair) do
    raw_connection = pair.client.backend.data

    fn payload ->
      Quicer.send_datagram(raw_connection, payload)
    end
  end

  defp with_pair(config, fun) do
    {:ok, ctx} = Transport.new(MOQX.Transport.Quicer)

    with {:ok, listener, ctx} <- start_listener(ctx, config),
         {:ok, {_ip, port}} <- Transport.local_address(ctx, listener),
         pair_started_at = monotonic_us(),
         {:ok, ctx, client, server} <- connect_pair(ctx, listener, port, config),
         {:ok, client_datagram} <- await_datagram_ready(client.backend.data, config.timeout_ms),
         {:ok, sink} <- start_server_sink(server) do
      pair = %{
        ctx: flush_transport_events(ctx),
        listener: listener,
        client: client,
        server: server,
        sink: sink,
        handshake_latency_ms: elapsed_ms(pair_started_at),
        client_datagram: client_datagram
      }

      try do
        case validate_negotiated_datagram_size(config, client_datagram) do
          :ok -> fun.(pair)
          {:error, reason} -> {:error, reason}
        end
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
      datagram_receive_enabled: 1,
      alpn: config.profile.alpn,
      certfile: config.certs.certfile,
      keyfile: config.certs.keyfile,
      peer_bidi_stream_count: 10,
      peer_unidi_stream_count: 10
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
    [
      datagram_receive_enabled: 1,
      alpn: config.profile.alpn,
      cacertfile: config.certs.cacertfile,
      verify: :verify_peer,
      server_name: "localhost",
      peer_bidi_stream_count: 10,
      peer_unidi_stream_count: 10
    ]
  end

  defp await_server_for_client(ctx, client, accept_task) do
    case Task.yield(accept_task, 5_000) || Task.shutdown(accept_task, :brutal_kill) do
      {:ok, {:ok, server, accept_ctx}} -> {:ok, merge_contexts(ctx, accept_ctx), client, server}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :accept_timeout}
    end
  end

  defp stop_accept_task(accept_task, reason) do
    Task.shutdown(accept_task, :brutal_kill)
    {:error, reason}
  end

  defp start_server_sink(server) do
    parent = self()

    sink =
      spawn_link(fn ->
        send(parent, {self(), :ready})
        server_sink_loop(0)
      end)

    receive do
      {^sink, :ready} ->
        case :quicer.controlling_process(server.backend.data, sink) do
          :ok -> {:ok, sink}
          {:error, reason} -> {:error, reason}
        end
    after
      1_000 -> {:error, :sink_start_timeout}
    end
  end

  defp server_sink_loop(received) do
    receive do
      {:stop, caller} ->
        send(caller, {:server_sink_stopped, self(), received})

      _message ->
        server_sink_loop(received + 1)
    end
  end

  defp stop_server_sink(pid) when is_pid(pid) do
    send(pid, {:stop, self()})

    receive do
      {:server_sink_stopped, ^pid, received} -> received
    after
      1_000 ->
        Process.exit(pid, :kill)
        nil
    end
  end

  defp await_datagram_ready(connection, timeout_ms) do
    started_at = monotonic_us()

    case await_datagram_ready_event(connection, monotonic_ms() + timeout_ms) do
      {:ok, datagram} ->
        {:ok, Map.put(datagram, :ready_latency_ms, elapsed_ms(started_at))}

      {:error, :timeout} ->
        case :quicer.getopt(connection, :datagram_send_enabled) do
          {:ok, true} ->
            {:ok,
             %{
               send_enabled: true,
               max_datagram_size: :unknown,
               source: "getopt",
               ready_latency_ms: elapsed_ms(started_at)
             }}

          {:ok, false} ->
            {:error, "Client DATAGRAM send capability is disabled."}

          {:error, reason} ->
            {:error, "Client DATAGRAM send capability was not observed: #{inspect(reason)}"}
        end
    end
  end

  defp await_datagram_ready_event(connection, deadline_ms) do
    remaining_ms = max(deadline_ms - monotonic_ms(), 0)

    receive do
      {:quic, :dgram_state_changed, ^connection,
       %{dgram_send_enabled: true, dgram_max_len: max_datagram_size}} ->
        {:ok,
         %{
           send_enabled: true,
           max_datagram_size: max_datagram_size,
           source: "dgram_state_changed"
         }}

      {:quic, :dgram_state_changed, ^connection, %{dgram_send_enabled: false}} ->
        await_datagram_ready_event(connection, deadline_ms)

      _message ->
        await_datagram_ready_event(connection, deadline_ms)
    after
      remaining_ms -> {:error, :timeout}
    end
  end

  defp validate_negotiated_datagram_size(config, %{max_datagram_size: max_datagram_size})
       when is_integer(max_datagram_size) and config.datagram_size > max_datagram_size do
    {:error,
     "--datagram-size #{config.datagram_size} exceeds negotiated DATAGRAM max #{max_datagram_size}."}
  end

  defp validate_negotiated_datagram_size(_config, _datagram), do: :ok

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
    _sink_received = stop_server_sink(pair.sink)
    _client_result = Transport.close_connection(pair.ctx, pair.client, 0)
    _server_result = Transport.close_connection(pair.ctx, pair.server, 0)
    _listener_result = Transport.close_listener(pair.ctx, pair.listener, 0)
    :ok
  end

  defp flush_transport_events(ctx) do
    receive do
      _message -> flush_transport_events(ctx)
    after
      0 -> ctx
    end
  end

  defp measure_bursts(_send_fun, _payload, 0, _burst_size, result), do: result

  defp measure_bursts(send_fun, payload, remaining, burst_size, result) do
    burst_count = min(remaining, burst_size)
    started_at = monotonic_us()
    {accepted, errors, error_reasons} = send_burst(send_fun, payload, burst_count, 0, 0, %{})
    duration_us = monotonic_us() - started_at

    result =
      result
      |> Map.update!(:accepted, &(&1 + accepted))
      |> Map.update!(:errors, &(&1 + errors))
      |> merge_error_reasons(error_reasons)
      |> Map.update!(:burst_durations_us, &[duration_us | &1])
      |> Map.update!(:burst_counts, &[burst_count | &1])
      |> Map.update!(:per_datagram_us, &[duration_us / burst_count | &1])

    measure_bursts(send_fun, payload, remaining - burst_count, burst_size, result)
  end

  defp send_burst(_send_fun, _payload, 0, accepted, errors, error_reasons),
    do: {accepted, errors, error_reasons}

  defp send_burst(send_fun, payload, remaining, accepted, errors, error_reasons) do
    case normalize_send_result(send_fun.(payload)) do
      :ok ->
        send_burst(send_fun, payload, remaining - 1, accepted + 1, errors, error_reasons)

      {:error, reason} ->
        send_burst(
          send_fun,
          payload,
          remaining - 1,
          accepted,
          errors + 1,
          increment_error_reason(error_reasons, reason)
        )
    end
  end

  defp normalize_send_result(:ok), do: :ok
  defp normalize_send_result({:ok, _ctx}), do: :ok
  defp normalize_send_result({:error, reason}), do: {:error, reason}
  defp normalize_send_result({:error, reason, _ctx}), do: {:error, reason}

  defp measure_paced_admissions(send_fun, payload, count, burst_size, target_rate, tick_ms) do
    ref = make_ref()
    started_ms = monotonic_ms()
    started_us = monotonic_us()
    first_tick_ms = started_ms + tick_ms
    schedule_tick(ref, first_tick_ms)

    result =
      paced_loop(send_fun, payload, %{
        ref: ref,
        started_ms: started_ms,
        started_us: started_us,
        next_tick_ms: first_tick_ms,
        count: count,
        burst_size: burst_size,
        target_rate: target_rate,
        tick_ms: tick_ms,
        accepted: 0,
        errors: 0,
        error_reasons: %{},
        burst_durations_us: [],
        burst_counts: [],
        per_datagram_us: [],
        tick_lags_ms: [],
        tick_due_counts: [],
        tick_send_counts: [],
        tick_count: 0,
        empty_tick_count: 0,
        capped_tick_count: 0,
        max_due_datagrams: 0
      })

    Map.put(result, :duration_us, monotonic_us() - started_us)
  end

  defp paced_loop(send_fun, payload, state) do
    sent = state.accepted + state.errors

    if sent >= state.count do
      drop_paced_private_state(state)
    else
      receive do
        {:sender_admission_tick, ref, scheduled_ms} when ref == state.ref ->
          now_ms = monotonic_ms()
          state = send_paced_tick(send_fun, payload, state, now_ms, scheduled_ms)
          sent = state.accepted + state.errors

          if sent >= state.count do
            paced_loop(send_fun, payload, state)
          else
            next_tick_ms = scheduled_ms + state.tick_ms
            schedule_tick(state.ref, next_tick_ms)
            paced_loop(send_fun, payload, %{state | next_tick_ms: next_tick_ms})
          end
      after
        10_000 ->
          state
          |> Map.put(:errors, state.errors + state.count - sent)
          |> drop_paced_private_state()
      end
    end
  end

  defp send_paced_tick(send_fun, payload, state, now_ms, scheduled_ms) do
    sent = state.accepted + state.errors
    remaining = state.count - sent
    elapsed_ms = max(now_ms - state.started_ms, 0)
    target_sent = min(state.count, div(elapsed_ms * state.target_rate, 1000))
    due = max(target_sent - sent, 0)
    to_send = min(due, min(state.burst_size, remaining))
    lag_ms = now_ms - scheduled_ms
    capped? = due > to_send and remaining > to_send

    state =
      state
      |> Map.update!(:tick_lags_ms, &[lag_ms | &1])
      |> Map.update!(:tick_due_counts, &[due | &1])
      |> Map.update!(:tick_send_counts, &[to_send | &1])
      |> Map.update!(:tick_count, &(&1 + 1))
      |> Map.update!(:max_due_datagrams, &max(&1, due))
      |> maybe_increment(:empty_tick_count, to_send == 0)
      |> maybe_increment(:capped_tick_count, capped?)

    if to_send == 0 do
      state
    else
      started_at = monotonic_us()
      {accepted, errors, error_reasons} = send_burst(send_fun, payload, to_send, 0, 0, %{})
      duration_us = monotonic_us() - started_at

      state
      |> Map.update!(:accepted, &(&1 + accepted))
      |> Map.update!(:errors, &(&1 + errors))
      |> merge_error_reasons(error_reasons)
      |> Map.update!(:burst_durations_us, &[duration_us | &1])
      |> Map.update!(:burst_counts, &[to_send | &1])
      |> Map.update!(:per_datagram_us, &[duration_us / to_send | &1])
    end
  end

  defp increment_error_reason(error_reasons, reason) do
    Map.update(error_reasons, inspect(reason), 1, &(&1 + 1))
  end

  defp merge_error_reasons(result, error_reasons) do
    Map.update!(result, :error_reasons, fn existing ->
      Map.merge(existing, error_reasons, fn _reason, left, right -> left + right end)
    end)
  end

  defp maybe_increment(state, key, true), do: Map.update!(state, key, &(&1 + 1))
  defp maybe_increment(state, _key, false), do: state

  defp schedule_tick(ref, scheduled_ms) do
    Process.send_after(self(), {:sender_admission_tick, ref, scheduled_ms}, scheduled_ms,
      abs: true
    )
  end

  defp drop_paced_private_state(state) do
    Map.drop(state, [
      :ref,
      :started_ms,
      :started_us,
      :next_tick_ms,
      :count,
      :burst_size,
      :target_rate,
      :tick_ms
    ])
  end

  defp build_record(args) do
    config = args.config
    measurement = args.measurement
    burst_budget_us = burst_budget_us(config)
    burst_duration_ms = duration_summary_ms(measurement.burst_durations_us)
    per_datagram_us = duration_summary_us(measurement.per_datagram_us)

    %{
      "schema_version" => @schema_version,
      "record_type" => "sender_admission_summary",
      "run" => run_metadata(args),
      "path" => path_metadata(config),
      "software" => software_metadata(),
      "profile" => profile_metadata(config, args.mode),
      "workload" => workload_metadata(config),
      "metrics" =>
        compact(%{
          "accepted_datagrams" => measurement.accepted,
          "send_errors" => measurement.errors,
          "send_error_reasons" => measurement.error_reasons,
          "duration_ms" => measurement.duration_us / 1000,
          "admission_rate_datagrams_per_second" =>
            rate(measurement.accepted, measurement.duration_us),
          "target_datagrams_per_second" => config.target_rate,
          "target_headroom_ratio" =>
            ratio(rate(measurement.accepted, measurement.duration_us), config.target_rate),
          "schedule" => config.schedule,
          "tick_ms" => config.tick_ms,
          "burst_size" => config.burst_size,
          "burst_budget_us" => burst_budget_us,
          "burst_duration_ms" => burst_duration_ms,
          "burst_over_budget_count" =>
            Enum.count(measurement.burst_durations_us, &(&1 > burst_budget_us)),
          "burst_over_budget_ratio" =>
            ratio(
              Enum.count(measurement.burst_durations_us, &(&1 > burst_budget_us)),
              length(measurement.burst_durations_us)
            ),
          "per_datagram_admission_us" => per_datagram_us,
          "tick_lag_ms" => duration_summary(measurement.tick_lags_ms),
          "tick_due_datagrams" => duration_summary(measurement.tick_due_counts),
          "tick_send_datagrams" => duration_summary(measurement.tick_send_counts),
          "tick_count" => measurement.tick_count,
          "empty_tick_count" => measurement.empty_tick_count,
          "capped_tick_count" => measurement.capped_tick_count,
          "max_due_datagrams" => measurement.max_due_datagrams,
          "sender_mailbox_depth" => mailbox_depth()
        }),
      "diagnostics" =>
        compact(%{
          "warmup_accepted_datagrams" => args.warmup_result.accepted,
          "warmup_send_errors" => args.warmup_result.errors,
          "warmup_send_error_reasons" => args.warmup_result.error_reasons,
          "warmup_duration_ms" => args.warmup_result.duration_us / 1000,
          "handshake_latency_ms" => args.pair.handshake_latency_ms,
          "client_datagram_ready_latency_ms" => args.pair.client_datagram.ready_latency_ms,
          "client_datagram_ready_source" => args.pair.client_datagram.source,
          "client_datagram_send_enabled" => args.pair.client_datagram.send_enabled,
          "client_datagram_max_size" => args.pair.client_datagram.max_datagram_size,
          "payload_reuse" => true,
          "server_receive_owner" => "sink_process"
        })
    }
  end

  defp run_metadata(args) do
    %{
      "run_id" => args.config.run_id,
      "started_at" => args.run_started_at,
      "finished_at" => args.run_finished_at,
      "git_sha" => BuildInfo.git_sha(),
      "script" => args.config.script,
      "script_version" => @script_version,
      "command" => args.config.command,
      "notes" => args.config.notes,
      "repetition_index" => args.repetition,
      "repetition_count" => args.config.repetitions
    }
  end

  defp path_metadata(config) do
    %{
      "evidence_tier" => "loopback_calibration",
      "path_id" => "loopback-#{config.host}-quicer-sender-admission",
      "client" => endpoint_metadata("client"),
      "server" => endpoint_metadata("server")
    }
  end

  defp endpoint_metadata(role) do
    %{
      "host_id" => "#{hostname()}-#{role}",
      "provider" => "local",
      "region" => "local",
      "instance_class" => "local",
      "os" => os_description(),
      "kernel" => kernel(),
      "cpu_model" => cpu_model(),
      "memory_bytes" => memory_bytes(),
      "nic_or_network_class" => "loopback"
    }
  end

  defp software_metadata do
    %{
      "elixir_version" => System.version(),
      "otp_version" => System.otp_release(),
      "moqx_version" => app_version(:moqx),
      "quicer_version" => app_version(:quicer),
      "msquic_version" => nil,
      "reference_implementation" => nil,
      "reference_version" => nil
    }
  end

  defp profile_metadata(config, mode) do
    %{
      "name" => Atom.to_string(config.profile.name),
      "alpn" => config.profile.alpn,
      "datagrams" => true,
      "congestion_control" => nil,
      "pacing" => nil,
      "settings" => %{
        "send_mode" => mode,
        "schedule" => config.schedule,
        "quicer_send_state_reports" => false
      }
    }
  end

  defp workload_metadata(config) do
    %{
      "family" => "sender_admission",
      "direction" => "client_to_server",
      "datagram_size_bytes" => config.datagram_size,
      "datagram_count" => config.datagram_count,
      "warmup_count" => config.warmup_count,
      "schedule" => config.schedule,
      "tick_ms" => config.tick_ms,
      "burst_size" => config.burst_size,
      "target_datagrams_per_second" => config.target_rate
    }
  end

  defp burst_budget_us(config), do: config.burst_size * 1_000_000 / config.target_rate

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
    if generated_certs_fresh?(certs) do
      :ok
    else
      generate_certs(certs)
    end
  end

  defp generated_certs_fresh?(certs) do
    [certs.certfile, certs.keyfile, certs.cacertfile]
    |> Enum.all?(&fresh_file?/1)
  end

  defp fresh_file?(path) do
    max_age_seconds = 6 * 24 * 60 * 60

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.system_time(:second) - mtime < max_age_seconds
      {:error, _reason} -> false
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

  defp json_ready(value) when is_map(value),
    do: Map.new(value, fn {key, map_value} -> {key, json_ready(map_value)} end)

  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value), do: value

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp duration_summary_ms(values_us) do
    values_us
    |> Enum.map(&(&1 / 1000))
    |> duration_summary()
  end

  defp duration_summary_us(values_us), do: duration_summary(values_us)

  defp duration_summary(values) do
    sorted = Enum.sort(values)
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

  defp percentile([], _percentile), do: nil

  defp percentile(sorted, percentile) do
    index =
      sorted
      |> length()
      |> Kernel.*(percentile)
      |> Float.ceil()
      |> trunc()
      |> max(1)
      |> Kernel.-(1)

    Enum.at(sorted, index)
  end

  defp rate(_count, 0), do: nil
  defp rate(count, duration_us), do: count * 1_000_000 / duration_us

  defp ratio(nil, _denominator), do: nil
  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: numerator / denominator

  defp monotonic_us, do: System.monotonic_time(:microsecond)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp elapsed_ms(started_at), do: (monotonic_us() - started_at) / 1000
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp default_run_id do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    "#{timestamp}-loopback-sender-admission"
  end

  defp command_string(script, argv), do: Enum.join([script | argv], " ")

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      version -> List.to_string(version)
    end
  end

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

  defp usage(script) do
    """
    Usage:
      #{script} [options]

    Local sender-only DATAGRAM admission microbenchmark.

    This is loopback calibration only. It measures how quickly the local sender
    can admit DATAGRAM send requests into the transport stack while a dedicated
    server-side sink process drains incoming DATAGRAM events.

    Options:
      --mode MODE                   moqx, quicer; repeatable (default: both)
      --profile NAME                draft_14 (default: draft_14)
      --host HOST                   Local listener/connect host (default: 127.0.0.1)
      --datagram-size BYTES         Reused datagram payload size (default: #{@default_datagram_size})
      --datagram-count N            Measured datagrams per repetition (default: 96000)
      --warmup-count N              Warmup datagrams before each measurement (default: 1024)
      --schedule MODE               burst or paced (default: burst)
      --tick-ms N                   Absolute timer tick for paced schedule (default: 1)
      --burst-size N                DATAGRAM calls per measured burst (default: 32)
      --target-rate N               Target datagrams/sec used for burst budget (default: 32000)
      --repetitions N               Repetitions per mode (default: 1)
      --timeout-ms N                Per-operation timeout in milliseconds (default: 5000)
      --cert-dir PATH               Generated cert directory (default: #{@default_cert_dir})
      --certfile PATH               Existing TLS certificate PEM file
      --keyfile PATH                Existing TLS private key PEM file
      --cacertfile PATH             Existing CA certificate PEM file
      --run-id ID                   Stable run identifier
      --output PATH                 Write JSONL records to path instead of stdout
      --notes TEXT                  Free-form run notes
      -h, --help                    Show this help
    """
  end
end
