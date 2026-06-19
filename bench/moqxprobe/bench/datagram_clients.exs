unless Mix.env() == :test or Code.ensure_loaded?(Benchee) do
  Mix.raise("Benchee is not available. Run `mix deps.get` in bench/moqxprobe first.")
end

defmodule MOQXProbe.Bench.DatagramClients do
  @moduledoc false

  alias MOQX.Transport
  alias MOQX.Transport.Quicer
  alias MOQXProbe.Benchee.Adapters
  alias MOQXProbe.Benchee.EvidenceCollector
  alias MOQXProbe.Benchee.RunMetadata
  alias MOQXProbe.Benchee.RunReceipt
  alias MOQXProbe.DatagramPayload
  alias MOQXProbe.Traffic.DatagramSender

  @input_names ["flow-sequence-timestamp"]
  @implementation_names ["paced_sink"]
  @target_names ["fake", "quicprobe"]
  @datagram_send_flags %{
    "dgram_priority" => :dgram_priority,
    "priority_work" => :priority_work,
    "cancel_on_blocked" => :cancel_on_blocked
  }
  @datagram_send_flag_names Map.keys(@datagram_send_flags)
  @profile_name "draft14_object_datagram"
  @quicprobe_experiment_lease_ttl_ms 30 * 60 * 1000
  @object_datagram_zero_evidence %{
    bidi_streams_accepted: 0,
    uni_streams_accepted: 0,
    streams_completed: 0,
    stream_bytes_received: 0,
    stream_bytes_echo_accepted: 0,
    stream_receive_error_count: 0,
    stream_send_error_count: 0
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
    datagram_count: :integer,
    datagram_size: :integer,
    datagram_rate: :integer,
    datagram_send_flag: :keep,
    max_burst: :integer,
    max_queue_depth: :integer,
    min_demand: :integer,
    max_demand: :integer,
    flow_stages: :integer,
    max_lag_ms: :integer,
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

    def record_datagram(nil, _receipt_id, _byte_size), do: :ok
    def record_datagram(_table, nil, _byte_size), do: :ok

    def record_datagram(table, receipt_id, byte_size) do
      increment(table, receipt_id, :datagrams_received, 1)
      increment(table, receipt_id, :datagram_bytes_received, byte_size)
    end

    def snapshot(table, receipt_id) do
      @counter_fields
      |> Map.new(fn field -> {field, counter(table, receipt_id, field)} end)
      |> Map.put(:datagram_semantics, "drain")
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

    alias MOQXProbe.Bench.DatagramClients.FakeEvidenceState

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
    def open_stream(_connection, _opts), do: {:error, :unsupported}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(_stream, _data, _opts), do: {:error, :unsupported}

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :unsupported}

    @impl true
    def send_datagram(connection, data), do: send_datagram(connection, data, [])

    @impl true
    def send_datagram({:fake_conn, _conn_ref, evidence_table, receipt_id}, data, _opts) do
      FakeEvidenceState.record_datagram(evidence_table, receipt_id, byte_size(data))
      :ok
    end

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
    def normalize_message(_message), do: :unknown

    @impl true
    def stream_info(_stream, _local_role, _initiator), do: {:error, :unsupported}

    @impl true
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}

    defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
    defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  end

  def run_paced_sink(input) do
    input = Map.put_new(input, :implementation, "paced_sink")
    started_at = receipt_timestamp(input)
    {ctx, connection} = setup_connection(input)

    snapshot =
      try do
        run_datagram_sender!(ctx, connection, input)
      rescue
        exception ->
          close_connection(ctx, connection)
          reraise exception, __STACKTRACE__
      end

    result = local_sender_summary(snapshot)

    cleanup = fn ->
      maybe_evidence_close_grace(input)
      close_connection(final_ctx(snapshot, ctx), connection)
      flush_mailbox()
    end

    unless evidence_enabled?(input), do: cleanup.()

    maybe_run_receipt(input, result, started_at, cleanup)
  end

  def jobs(options) do
    all = %{
      "paced_sink" => fn input ->
        input |> Map.put(:implementation, "paced_sink") |> run_paced_sink()
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
      path -> Keyword.put(config, :save, path: path, tag: "datagram-clients")
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
    rate = positive_integer(opts, :datagram_rate, 1_000)
    max_burst = positive_integer(opts, :max_burst, DatagramSender.default_max_burst(rate))

    base = %{
      target: target(opts),
      host: Keyword.get(opts, :host, "127.0.0.1"),
      quic_port: positive_integer(opts, :quic_port, 4433),
      iperf_port: positive_integer(opts, :iperf_port, 5201),
      ca: Keyword.get(opts, :ca),
      servername: Keyword.get(opts, :servername, "localhost"),
      alpn: Keyword.get(opts, :alpn, "moqx-test"),
      connect_timeout_ms: positive_integer(opts, :connect_timeout_ms, 5_000),
      datagram_count: positive_integer(opts, :datagram_count, 1_000),
      datagram_size: positive_integer(opts, :datagram_size, 1_180),
      datagram_rate: rate,
      datagram_send_flags: datagram_send_flags(opts),
      max_burst: max_burst,
      max_queue_depth:
        positive_integer(
          opts,
          :max_queue_depth,
          DatagramSender.default_max_queue_depth(max_burst)
        ),
      flow_stages: positive_integer(opts, :flow_stages, 1),
      max_lag_ms: non_negative_integer_or_nil(opts, :max_lag_ms),
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
    |> validate_datagram_size!()
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

  defp non_negative_integer_or_nil(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      value when is_integer(value) and value >= 0 -> value
      _invalid -> Mix.raise("--#{cli_key(key)} must be a non-negative integer")
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

  defp validate_datagram_size!(%{datagram_size: size} = options) do
    if size >= DatagramPayload.header_size() do
      options
    else
      Mix.raise("--datagram-size must be at least #{DatagramPayload.header_size()} bytes")
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

  defp datagram_send_flags(opts) do
    opts
    |> Keyword.get_values(:datagram_send_flag)
    |> Enum.map(&datagram_send_flag!/1)
  end

  defp datagram_send_flag!(name) when is_binary(name) do
    case Map.fetch(@datagram_send_flags, name) do
      {:ok, flag} ->
        flag

      :error ->
        Mix.raise(
          "--datagram-send-flag must be one of #{Enum.join(@datagram_send_flag_names, ", ")}; " <>
            "got #{name}"
        )
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

  defp input_for("flow-sequence-timestamp", base),
    do: Map.put(base, :producer, :flow_sequence_timestamp)

  defp setup_connection(%{target: :fake} = input) do
    {:ok, ctx} = Transport.new(FakeTransport, fake_transport_opts(input))
    {:ok, connection, ctx} = Transport.connect(ctx, "localhost", 4433, [], 1_000)
    {ctx, connection}
  end

  defp setup_connection(%{target: :quicprobe} = input) do
    {:ok, ctx} = Transport.new(Quicer, datagram_send_flags: input.datagram_send_flags)

    {:ok, connection, ctx} =
      Transport.connect(
        ctx,
        input.host,
        input.quic_port,
        quicprobe_connect_opts(input),
        input.connect_timeout_ms
      )

    {ctx, connection}
  end

  defp quicprobe_connect_opts(input) do
    [
      alpn: input.alpn,
      cacertfile: input.ca,
      verify: :verify_peer,
      server_name: input.servername
    ]
  end

  defp fake_transport_opts(input) do
    [
      evidence_table: Map.get(input, :evidence_table),
      receipt_id: Map.get(input, :receipt_id)
    ]
  end

  defp run_datagram_sender!(ctx, connection, input) do
    opts =
      [
        count: input.datagram_count,
        rate_per_second: input.datagram_rate,
        started_at_us: monotonic_us(),
        payload_mode: {:sequence_timestamp, input.datagram_size},
        send_fun: datagram_send_fun(input),
        transport_state: %{ctx: ctx, connection: connection},
        timeout: input.timeout_ms,
        max_burst: input.max_burst,
        min_demand: input.min_demand,
        max_demand: input.max_demand,
        max_queue_depth: input.max_queue_depth,
        stages: input.flow_stages
      ]
      |> maybe_put_max_lag(input.max_lag_ms)

    case DatagramSender.run(opts) do
      {:ok, snapshot} ->
        snapshot

      {:error, reason, snapshot} ->
        raise "datagram benchmark failed: #{inspect(reason)} snapshot=#{inspect(local_sender_summary(snapshot))}"

      {:error, reason} ->
        raise "datagram benchmark failed: #{inspect(reason)}"
    end
  end

  defp maybe_put_max_lag(opts, nil), do: opts
  defp maybe_put_max_lag(opts, max_lag_ms), do: Keyword.put(opts, :max_lag_ms, max_lag_ms)

  defp datagram_send_fun(input) do
    fn payload, %{ctx: ctx, connection: connection} = transport_state ->
      data = encode_payload(payload, input)

      case Transport.send_datagram(ctx, connection, data) do
        {:ok, ctx} -> {:ok, %{transport_state | ctx: ctx}}
        {:error, reason, ctx} -> {:error, reason, %{transport_state | ctx: ctx}}
      end
    end
  end

  defp encode_payload(%{sequence: sequence, padding: padding}, _input) do
    DatagramPayload.encode(sequence, monotonic_us(), padding)
  end

  defp encode_payload(payload, _input) when is_binary(payload), do: payload

  defp close_connection(ctx, connection) do
    case Transport.close_connection(ctx, connection, 0) do
      {:ok, _ctx} -> :ok
      {:error, _reason, _ctx} -> :ok
    end
  end

  defp final_ctx(%{transport_state: %{ctx: ctx}}, _fallback), do: ctx
  defp final_ctx(_snapshot, fallback), do: fallback

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
    Map.merge(@object_datagram_zero_evidence, %{
      datagram_semantics: "drain",
      datagrams_received: input.datagram_count,
      datagram_bytes_received: input.datagram_count * input.datagram_size
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
      datagram_count: input.datagram_count,
      datagram_size: input.datagram_size,
      datagram_rate: input.datagram_rate,
      datagram_send_flags: input.datagram_send_flags,
      max_burst: input.max_burst,
      max_queue_depth: input.max_queue_depth,
      min_demand: input.min_demand,
      max_demand: input.max_demand,
      flow_stages: input.flow_stages,
      max_lag_ms: input.max_lag_ms,
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

  defp local_sender_summary(snapshot) do
    %{
      accepted: snapshot.accepted,
      errors: snapshot.errors,
      error_reasons: snapshot.error_reasons,
      stop_reason: snapshot.stop_reason,
      queue_depth: snapshot.queue_depth,
      outstanding_demand: snapshot.outstanding_demand,
      max_queue_depth: snapshot.max_queue_depth,
      payload_producer_result: Map.get(snapshot, :payload_producer_result),
      burst_count: length(snapshot.burst_counts),
      burst_send_count_max: Enum.max(snapshot.burst_counts, fn -> 0 end),
      tick_count: length(snapshot.tick_send_counts),
      tick_lag_ms_max: Enum.max(snapshot.tick_lags_ms, fn -> 0 end)
    }
  end

  defp producer_name(:flow_sequence_timestamp), do: "flow-sequence-timestamp"

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
      mix run bench/datagram_clients.exs -- [options]

    Target:
      --target NAME                fake or quicprobe (default: fake)
      --host HOST                  quicprobe host for --target quicprobe (default: 127.0.0.1)
      --quic-port PORT             quicprobe UDP port (default: 4433)
      --iperf-port PORT            iperf3 TCP/UDP baseline port metadata (default: 5201)
      --ca PATH                    trusted CA PEM for --target quicprobe
      --servername NAME            TLS server name (default: localhost)
      --alpn VALUE                 QUIC ALPN (default: moqx-test)
      --connect-timeout-ms N       QUIC connect timeout (default: 5000)
                                   quicprobe targets must use --datagram-semantics drain

    Workload:
      --datagram-count N           number of DATAGRAMs per invocation (default: 1000)
      --datagram-size BYTES        DATAGRAM payload bytes; minimum 16 (default: 1180)
      --datagram-rate N            target DATAGRAMs per second (default: 1000)
      --datagram-send-flag NAME    repeatable quicer flag: dgram_priority, priority_work, cancel_on_blocked
      --max-burst N                max sends emitted by one tick (default: ceil(rate / 1000))
      --max-queue-depth N          Flow-to-sink queue bound (default: max_burst * 4 or 64)
      --min-demand N               Flow min demand (default: max_burst - 1)
      --max-demand N               Flow max demand (default: max_burst)
      --flow-stages N              Flow producer stages (default: 1)
      --max-lag-ms N               optional pacing lag cap
      --timeout-ms N               per invocation timeout (default: 15000)

    Matrix:
      --input NAME                 repeatable; flow-sequence-timestamp
      --implementation NAME        repeatable; paced_sink

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

    Run metadata:
      --git-sha SHA                  git SHA metadata (default: current HEAD)
      --iperf-preflight-summary PATH repeatable iperf3 JSON summary sidecar
      --tailscale-path-mode MODE     optional Tailscale path mode, e.g. direct or relay
      --server-stats-path PATH       optional server stats/evidence path metadata

    Example:
      mix run bench/datagram_clients.exs -- --datagram-count 10000 --datagram-rate 30000 --benchee-time 3
    """
  end

  def main(argv \\ System.argv()) do
    options =
      argv
      |> parse_cli!()
      |> prepare_run!()

    try do
      apply(Benchee, :run, [jobs(options), benchee_config(options)])

      write_evidence!(options)
    after
      cleanup_run(options)
    end
  end
end

unless Mix.env() == :test do
  MOQXProbe.Bench.DatagramClients.main()
end
