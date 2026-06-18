unless Code.ensure_loaded?(Benchee) do
  Mix.raise("Benchee is not available. Run `mix deps.get` in bench/moqxprobe first.")
end

defmodule MOQXProbe.Bench.StreamClients do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info
  alias MOQX.Transport.Quicer
  alias MOQXProbe.Traffic.StreamSender

  @input_names ["flow-generated", "flow-prebuilt-list"]
  @implementation_names ["context_owner", "stream_owner"]
  @target_names ["fake", "quicprobe"]
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
    max_burst: :integer,
    max_queue_depth: :integer,
    min_demand: :integer,
    max_demand: :integer,
    idle_retries: :integer,
    event_batch_size: :integer,
    timeout_ms: :integer,
    input: :string,
    implementation: :string,
    benchee_warmup: :float,
    benchee_time: :float,
    benchee_memory_time: :float,
    benchee_reduction_time: :float,
    benchee_parallel: :integer,
    save: :string
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
    def open_stream(connection, opts) do
      direction = option(opts, :direction, :unidirectional)
      {:ok, {:fake_stream, elem(connection, 1), make_ref(), direction}}
    end

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(stream, _data, _opts) do
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

  def run_context_owner(input) do
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

    try do
      drive_context_owner(sender, ctx, count, input)
    after
      _snapshot = StreamSender.stop(sender)
      close_connection(ctx, connection)
      flush_mailbox()
    end
  end

  def run_stream_owner(input) do
    {ctx, streams, connection} = setup_streams(input)
    payload = payload(input)
    deadline_us = monotonic_us() + input.timeout_ms * 1_000

    try do
      streams
      |> Enum.map(fn stream_state ->
        Task.async(fn ->
          run_stream_owner_worker(stream_state.stream, payload, input, deadline_us)
        end)
      end)
      |> Task.await_many(input.timeout_ms + 1_000)
      |> Enum.reduce(%{accepted: 0, completed: 0}, fn result, acc ->
        %{
          accepted: acc.accepted + result.accepted,
          completed: acc.completed + result.completed
        }
      end)
    after
      close_connection(ctx, connection)
      flush_mailbox()
    end
  end

  def jobs(options) do
    all = %{
      "context_owner" => &run_context_owner/1,
      "stream_owner" => &run_stream_owner/1
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

    case options.benchee.save do
      nil -> config
      path -> Keyword.put(config, :save, path: path, tag: "stream-clients")
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
      max_burst: max_burst,
      max_queue_depth: positive_integer(opts, :max_queue_depth, 256),
      idle_retries: non_negative_integer(opts, :idle_retries, 1_000),
      event_batch_size: positive_integer(opts, :event_batch_size, 1_024),
      timeout_ms: positive_integer(opts, :timeout_ms, 15_000)
    }

    base
    |> Map.put(:min_demand, non_negative_integer(opts, :min_demand, max(base.max_burst - 1, 0)))
    |> Map.put(:max_demand, positive_integer(opts, :max_demand, base.max_burst))
    |> validate_flow_demand!()
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
    {:ok, ctx} = Transport.new(FakeTransport, [])
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
        %{accepted: snapshot.accepted, completed: snapshot.completed}

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

  defp run_stream_owner_worker(stream, payload, input, deadline_us) do
    {:ok, sender} = Stream.sender(stream)

    {sender, state} =
      schedule_stream_owner_window(
        sender,
        %{accepted: 0, completed: 0, in_flight: 0},
        payload,
        input
      )

    drive_stream_owner(state, sender, payload, input, deadline_us)
  end

  defp drive_stream_owner(state, _sender, _payload, input, _deadline_us)
       when state.completed >= input.payload_count do
    state
  end

  defp drive_stream_owner(state, sender, payload, input, deadline_us) do
    if monotonic_us() >= deadline_us do
      raise "stream_owner benchmark timed out with #{state.completed} completions"
    else
      {sender, state} = receive_stream_owner_batch(sender, state, input, deadline_us)

      {sender, state} = schedule_stream_owner_window(sender, state, payload, input)
      drive_stream_owner(state, sender, payload, input, deadline_us)
    end
  end

  defp schedule_stream_owner_window(sender, state, payload, input) do
    if state.accepted < input.payload_count and state.in_flight < input.stream_send_window do
      finish? = state.accepted + 1 == input.payload_count
      {:ok, _send, sender} = Stream.Sender.send(sender, payload, finish: finish?)

      schedule_stream_owner_window(
        sender,
        %{state | accepted: state.accepted + 1, in_flight: state.in_flight + 1},
        payload,
        input
      )
    else
      {sender, state}
    end
  end

  defp receive_stream_owner_batch(sender, state, input, deadline_us) do
    timeout_ms = max(div(deadline_us - monotonic_us(), 1_000), 0)

    case Stream.Sender.receive_event(sender, timeout_ms) do
      {:ok, {:stream_event, _stream, :send_completed, _metadata}, sender} ->
        state = complete_stream_owner(state)
        drain_ready_stream_owner(sender, state, input.event_batch_size - 1)

      {:ok, _event, sender} ->
        {sender, state}

      {:unknown, _message, sender} ->
        {sender, state}

      {:error, reason, _sender} ->
        raise "stream_owner receive failed: #{inspect(reason)}"

      {:timeout, _sender} ->
        raise "stream_owner completion timeout"
    end
  end

  defp drain_ready_stream_owner(sender, state, remaining) when remaining <= 0, do: {sender, state}

  defp drain_ready_stream_owner(sender, state, remaining) do
    case Stream.Sender.receive_event(sender, 0) do
      {:ok, {:stream_event, _stream, :send_completed, _metadata}, sender} ->
        drain_ready_stream_owner(sender, complete_stream_owner(state), remaining - 1)

      {:ok, _event, sender} ->
        drain_ready_stream_owner(sender, state, remaining - 1)

      {:unknown, _message, sender} ->
        drain_ready_stream_owner(sender, state, remaining - 1)

      {:timeout, sender} ->
        {sender, state}

      {:error, reason, _sender} ->
        raise "stream_owner drain failed: #{inspect(reason)}"
    end
  end

  defp complete_stream_owner(state) do
    %{state | completed: state.completed + 1, in_flight: max(state.in_flight - 1, 0)}
  end

  defp events(%{producer: :flow_prebuilt_list} = input, streams, payload) do
    StreamSender.events_for(
      streams: streams,
      payload: payload,
      payload_count: input.payload_count
    )
  end

  defp events(%{producer: :flow_generated}, _streams, _payload), do: nil

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
      --max-burst N                max sends emitted by one StreamSink tick (default: 64)
      --max-queue-depth N          Flow-to-sink queue bound (default: 256)
      --min-demand N               Flow min demand (default: max_burst - 1)
      --max-demand N               Flow max demand (default: max_burst)
      --idle-retries N             empty-drain retries before returning (default: 1000)
      --event-batch-size N         ready completion drain limit (default: 1024)
      --timeout-ms N               per invocation timeout (default: 15000)

    Matrix:
      --input NAME                 repeatable; flow-generated or flow-prebuilt-list
      --implementation NAME        repeatable; context_owner or stream_owner

    Benchee:
      --benchee-warmup SECONDS     default: 1.0
      --benchee-time SECONDS       default: 3.0
      --benchee-memory-time SEC    default: 0.0
      --benchee-reduction-time SEC default: 0.0
      --benchee-parallel N         default: 1
      --save PATH                  save Benchee suite for later comparison

    Example:
      mix run bench/stream_clients.exs -- --stream-count 32 --payload-count 1000 --stream-send-window 16 --benchee-time 3
    """
  end
end

options = MOQXProbe.Bench.StreamClients.parse_cli!(System.argv())

Benchee.run(
  MOQXProbe.Bench.StreamClients.jobs(options),
  MOQXProbe.Bench.StreamClients.benchee_config(options)
)
