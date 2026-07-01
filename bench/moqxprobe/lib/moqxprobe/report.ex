defmodule MOQXProbe.Report do
  @moduledoc """
  Derives comparison-ready metrics from a benchmark run's manifest and sidecars
  and renders a human-readable `report.md`, per the report/derivation layer of
  ADR-0009 (`docs/adr/0009-layered-benchmark-evidence-contract.md`).

  This module is PURE: `build/1` takes already-parsed manifest + sidecar data
  (string-keyed maps, as produced by `JSON.decode!`) and returns a structured
  report; `to_markdown/1` renders it. All file I/O and JSONL parsing live in the
  caller (`bench/report.exs`).

  Every derived metric carries its source layer, denominator/window, and the
  run's confidence tier, and its name is validated against the ADR-0009 naming
  rules (`build_metric/1` raises on a naked `bandwidth`/`goodput` or a
  stream `pkts/s`). Metrics from different measurement modes must not be
  compared; `build/1` emits a warning when a closed-loop run is tagged with a
  `remote_quic_*` tier (a ranking, not a saturation claim).

  Caveats honored (recorded on issue 54):

    * Receiver goodput uses the stream clocks for stream bytes and the datagram
      clocks for datagrams; the two origins are never mixed.
    * Interval per-bin rates assume each bin's window is `bin_width_ms`; the
      final quicprobe bin can be cap-folded, so the report notes this rather
      than trusting a single tail bin.
  """

  @forbidden_substrings ["bandwidth", "pkts", "packets_per_second"]

  @doc """
  Builds the structured report from parsed inputs.

  `inputs` keys (all optional except `:manifest`):

    * `:manifest` - decoded manifest map (string keys)
    * `:delivery` - list of decoded delivery-evidence records
    * `:paced` - `%{"header" => .., "ticks" => [..], "summary" => ..}` or nil
    * `:host` - `%{"header" => .., "samples" => [..]}` or nil
    * `:iperf3` - list of iperf3 summary maps (or nil)
  """
  @spec build(map()) :: map()
  def build(inputs) when is_map(inputs) do
    manifest = Map.fetch!(inputs, :manifest)
    mode = get(manifest, "mode")
    tier = get(manifest, "tier")
    target_type = get(manifest, "target_type")

    ctx = %{mode: mode, tier: tier, target_type: target_type}

    {receiver_metrics, receiver_notes} = receiver_metrics(Map.get(inputs, :delivery, []), ctx)
    {sender_metrics, sender_notes} = sender_metrics(Map.get(inputs, :paced), ctx)
    saturation = saturation_summary(Map.get(inputs, :host))

    {baseline, baseline_notes} =
      baseline_comparison(manifest, Map.get(inputs, :iperf3), receiver_metrics)

    metrics = receiver_metrics ++ sender_metrics

    %{
      mode: mode,
      tier: tier,
      target_type: target_type,
      run_id: get(manifest, "run_id"),
      git_sha: get(manifest, "git_sha"),
      target: get(manifest, "target"),
      workload: get(manifest, "workload"),
      client_implementation: get(manifest, "client_implementation"),
      metrics: metrics,
      saturation: saturation,
      baseline: baseline,
      warnings: warnings(ctx) ++ receiver_notes ++ sender_notes ++ baseline_notes
    }
  end

  @doc """
  Constructs a derived metric, validating its name against the ADR-0009 naming
  rules. Raises `ArgumentError` on a forbidden name so an ambiguous metric can
  never reach a report.
  """
  @spec build_metric(keyword()) :: map()
  def build_metric(fields) do
    name = Keyword.fetch!(fields, :name)
    validate_metric_name!(name)

    %{
      name: name,
      value: Keyword.fetch!(fields, :value),
      unit: Keyword.fetch!(fields, :unit),
      window: Keyword.get(fields, :window),
      source_layer: Keyword.fetch!(fields, :source_layer),
      tier: Keyword.get(fields, :tier)
    }
  end

  @doc """
  Validates a derived-metric name against ADR-0009. Raises `ArgumentError` on a
  naked `bandwidth`, a `goodput` name that does not end in `_bps`, or any
  `pkts`/`packets_per_second` name (only packet-capture sources may report
  packet rates, which this layer does not produce).
  """
  @spec validate_metric_name!(String.t()) :: :ok
  def validate_metric_name!(name) when is_binary(name) do
    cond do
      Enum.any?(@forbidden_substrings, &String.contains?(name, &1)) ->
        raise ArgumentError,
              "forbidden metric name #{inspect(name)}: no naked bandwidth and no stream pkts/s (ADR-0009)"

      String.contains?(name, "goodput") and not String.ends_with?(name, "_bps") ->
        raise ArgumentError,
              "goodput metric #{inspect(name)} must name its denominator and end in _bps (ADR-0009)"

      true ->
        :ok
    end
  end

  # --- receiver evidence -----------------------------------------------------

  defp receiver_metrics(delivery, ctx) when is_list(delivery) do
    valid = Enum.filter(delivery, &(get_in_ev(&1, ["valid"]) == true))

    cond do
      delivery == [] ->
        {[], []}

      valid == [] ->
        {[], ["No valid receiver-evidence records; receiver goodput omitted."]}

      true ->
        metrics =
          []
          |> maybe_append(stream_goodput_metric(valid, ctx))
          |> maybe_append(interval_p95_metric(valid, ctx))
          |> maybe_append(datagram_rate_metric(valid, ctx))

        {metrics, receiver_caveats(valid)}
    end
  end

  defp receiver_metrics(_delivery, _ctx), do: {[], []}

  # Per-record stream goodput over the stream-active window, reported as a
  # distribution across valid records (one connection each).
  defp stream_goodput_metric(valid, ctx) do
    samples =
      valid
      |> Enum.map(&record_stream_bps/1)
      |> Enum.reject(&is_nil/1)

    if samples == [] do
      nil
    else
      build_metric(
        name: "receiver_payload_goodput_active_bps",
        value: distribution(samples),
        unit: "bits_per_second",
        window: "receiver_active",
        source_layer: "receiver",
        tier: ctx.tier
      )
    end
  end

  defp record_stream_bps(record) do
    observed = get_in_ev(record, ["observed"]) || %{}
    interval = get_in_ev(record, ["metadata", "receiver_interval"]) || %{}
    bytes = num(Map.get(observed, "stream_bytes_received"))
    first = num(Map.get(interval, "first_stream_byte_at_ms"))
    last = num(Map.get(interval, "last_stream_byte_at_ms"))

    bps_over_window(bytes, first, last)
  end

  # Pooled per-bin stream goodput p95 across all valid records' interval bins.
  defp interval_p95_metric(valid, ctx) do
    per_bin_bps =
      valid
      |> Enum.flat_map(&record_bin_bps/1)
      |> Enum.reject(&is_nil/1)

    if per_bin_bps == [] do
      nil
    else
      build_metric(
        name: "receiver_payload_goodput_interval_p95_bps",
        value: percentile(per_bin_bps, 0.95),
        unit: "bits_per_second",
        window: "interval_bin",
        source_layer: "receiver",
        tier: ctx.tier
      )
    end
  end

  defp record_bin_bps(record) do
    interval = get_in_ev(record, ["metadata", "receiver_interval"]) || %{}
    width_ms = num(Map.get(interval, "bin_width_ms"))
    bins = Map.get(interval, "bins") || []

    if is_number(width_ms) and width_ms > 0 do
      Enum.map(bins, &bin_bps(&1, width_ms))
    else
      []
    end
  end

  defp bin_bps(bin, width_ms) do
    bytes = num(Map.get(bin, "stream_bytes"))
    if is_number(bytes), do: bytes * 8 * 1000 / width_ms, else: nil
  end

  defp datagram_rate_metric(valid, ctx) do
    samples =
      valid
      |> Enum.map(&record_datagram_rate/1)
      |> Enum.reject(&is_nil/1)

    if samples == [] do
      nil
    else
      build_metric(
        name: "datagrams_received_per_second",
        value: distribution(samples),
        unit: "datagrams_per_second",
        window: "receiver_active",
        source_layer: "receiver",
        tier: ctx.tier
      )
    end
  end

  defp record_datagram_rate(record) do
    observed = get_in_ev(record, ["observed"]) || %{}
    interval = get_in_ev(record, ["metadata", "receiver_interval"]) || %{}
    count = num(Map.get(observed, "datagrams_received"))
    first = num(Map.get(interval, "first_datagram_at_ms"))
    last = num(Map.get(interval, "last_datagram_at_ms"))

    if is_number(count) and count > 0 do
      per_second_over_window(count, first, last)
    else
      nil
    end
  end

  defp receiver_caveats(valid) do
    max_bins =
      valid
      |> Enum.map(fn record ->
        interval = get_in_ev(record, ["metadata", "receiver_interval"]) || %{}
        length(Map.get(interval, "bins") || [])
      end)
      |> Enum.max(fn -> 0 end)

    if max_bins >= 36_000 do
      [
        "Interval bins reached the quicprobe cap (36000); the final bin is " <>
          "cap-folded and its effective window is not bin_width_ms — treat the " <>
          "interval p95 as a lower bound."
      ]
    else
      []
    end
  end

  # --- sender evidence (open-loop paced) -------------------------------------

  defp sender_metrics(nil, _ctx), do: {[], []}

  defp sender_metrics(paced, ctx) when is_map(paced) do
    header = Map.get(paced, "header") || %{}
    summary = Map.get(paced, "summary") || %{}

    accepted = num(Map.get(summary, "accepted_payload_events_sender_active_total"))
    payload_size = num(Map.get(header, "payload_size"))
    duration_ms = num(Map.get(header, "duration_ms"))

    metrics =
      maybe_append([], sender_goodput_metric(accepted, payload_size, duration_ms, ctx))

    {metrics, coordinated_omission_notes(summary)}
  end

  defp sender_goodput_metric(accepted, payload_size, duration_ms, ctx)
       when is_number(accepted) and is_number(payload_size) and is_number(duration_ms) and
              duration_ms > 0 do
    bps = accepted * payload_size * 8 * 1000 / duration_ms

    build_metric(
      name: "client_payload_goodput_sender_active_bps",
      value: bps,
      unit: "bits_per_second",
      window: "sender_active",
      source_layer: "sender",
      tier: ctx.tier
    )
  end

  defp sender_goodput_metric(_accepted, _payload_size, _duration_ms, _ctx), do: nil

  defp coordinated_omission_notes(summary) do
    if Map.get(summary, "coordinated_omission") == true do
      cause = Map.get(summary, "coordinated_omission_cause")

      [
        "Coordinated omission detected (cause=#{cause}): the offered rate was " <>
          "not sustained, so latency-under-load is not trustworthy here. " <>
          "Corrected latency percentiles are deferred to issue 56."
      ]
    else
      []
    end
  end

  # --- host saturation -------------------------------------------------------

  defp saturation_summary(nil), do: nil

  defp saturation_summary(host) when is_map(host) do
    samples = Map.get(host, "samples") || []

    if samples == [] do
      nil
    else
      %{
        sample_count: length(samples),
        max_scheduler_utilization_fraction: max_number(samples, "scheduler_utilization_fraction"),
        max_total_run_queue_length: max_number(samples, "total_run_queue_length"),
        max_role_message_queue_len: max_role_mailbox(samples)
      }
    end
  end

  # --- iperf3 path baseline --------------------------------------------------

  # Only compared when the manifest names a real target/path (ADR-0009).
  defp baseline_comparison(manifest, iperf3, receiver_metrics)
       when is_list(iperf3) and iperf3 != [] do
    target = get(manifest, "target")

    if is_map(target) do
      # RunMetadata.iperf3_summaries/1 returns atom-keyed maps with status: :ok.
      baseline = Enum.find(iperf3, &(Map.get(&1, :status) == :ok)) || List.first(iperf3)
      baseline_bps = num(Map.get(baseline || %{}, :bits_per_second))
      receiver_bps = median_receiver_bps(receiver_metrics)

      utilization =
        if is_number(baseline_bps) and baseline_bps > 0 and is_number(receiver_bps) do
          receiver_bps / baseline_bps
        end

      {%{
         protocol: Map.get(baseline || %{}, :protocol),
         path_baseline_bps: baseline_bps,
         receiver_active_utilization: utilization
       }, []}
    else
      {nil,
       [
         "iperf3 baseline present but the manifest has no explicit target; baseline comparison skipped."
       ]}
    end
  end

  defp baseline_comparison(_manifest, _iperf3, _receiver_metrics), do: {nil, []}

  # --- warnings --------------------------------------------------------------

  defp warnings(%{mode: "closed_loop", tier: tier}) when is_binary(tier) do
    if String.starts_with?(tier, "remote_quic") do
      [
        "Closed-loop run tagged #{tier}: closed-loop numbers rank client " <>
          "implementations (service time), they are not a remote saturation " <>
          "claim. Do not compare them with open-loop numbers (ADR-0009)."
      ]
    else
      []
    end
  end

  defp warnings(_ctx), do: []

  # --- markdown --------------------------------------------------------------

  @doc """
  Renders the structured report as Markdown.
  """
  @spec to_markdown(map()) :: String.t()
  def to_markdown(report) do
    [
      "# Benchmark run report",
      "",
      "- run id: `#{report.run_id}`",
      "- mode: **#{report.mode}** · tier: **#{report.tier}** · target type: #{report.target_type}",
      "- git sha: `#{report.git_sha}` · client: #{report.client_implementation || "n/a"}",
      "",
      warnings_section(report.warnings),
      metrics_section(report.metrics),
      baseline_section(report.baseline),
      saturation_section(report.saturation),
      "",
      "_Derived per ADR-0009. Each metric names its source layer, window, and " <>
        "confidence tier. Benchee `ips` (closed-loop service time) is not a " <>
        "goodput figure and lives in the saved `.benchee` file._"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp warnings_section([]), do: ""

  defp warnings_section(warnings) do
    ["## Warnings", "" | Enum.map(warnings, &"- ⚠️ #{&1}")]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp metrics_section([]), do: "## Derived metrics\n\n_No derived metrics for this run._\n"

  defp metrics_section(metrics) do
    rows = Enum.map(metrics, &metric_row/1)

    [
      "## Derived metrics",
      "",
      "| metric | value | window | source | tier |",
      "| --- | --- | --- | --- | --- |" | rows
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp metric_row(metric) do
    "| `#{metric.name}` | #{format_value(metric.value)} | #{metric.window} | #{metric.source_layer} | #{metric.tier} |"
  end

  defp baseline_section(nil), do: ""

  defp baseline_section(baseline) do
    util =
      case baseline.receiver_active_utilization do
        nil -> "n/a"
        u -> "#{Float.round(u * 100, 1)}%"
      end

    """
    ## Path baseline (iperf3)

    - protocol: #{baseline.protocol}
    - `path_baseline_#{baseline.protocol}_bps`: #{format_number(baseline.path_baseline_bps)}
    - receiver-active utilization of baseline: #{util}
    """
  end

  defp saturation_section(nil), do: ""

  defp saturation_section(saturation) do
    """
    ## Host saturation (out-of-band samples)

    - samples: #{saturation.sample_count}
    - peak scheduler utilization: #{format_fraction(saturation.max_scheduler_utilization_fraction)}
    - peak total run-queue length: #{saturation.max_total_run_queue_length}
    - peak sender-role mailbox depth: #{saturation.max_role_message_queue_len}
    """
  end

  # --- helpers ---------------------------------------------------------------

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, item), do: list ++ [item]

  defp bps_over_window(bytes, first_ms, last_ms) do
    per_second_over_window(bytes, first_ms, last_ms)
    |> case do
      nil -> nil
      per_second -> per_second * 8
    end
  end

  defp per_second_over_window(count, first_ms, last_ms)
       when is_number(count) and is_number(first_ms) and is_number(last_ms) and last_ms > first_ms do
    count * 1000 / (last_ms - first_ms)
  end

  defp per_second_over_window(_count, _first, _last), do: nil

  defp distribution(samples) do
    sorted = Enum.sort(samples)

    %{
      count: length(sorted),
      min: List.first(sorted),
      median: percentile(sorted, 0.5),
      p95: percentile(sorted, 0.95),
      max: List.last(sorted)
    }
  end

  defp percentile([], _q), do: nil

  defp percentile(samples, q) do
    sorted = Enum.sort(samples)
    index = max(ceil(length(sorted) * q) - 1, 0)
    Enum.at(sorted, index)
  end

  defp median_receiver_bps(metrics) do
    Enum.find_value(metrics, fn metric ->
      if metric.name == "receiver_payload_goodput_active_bps" and is_map(metric.value) do
        Map.get(metric.value, :median)
      end
    end)
  end

  defp max_number(samples, key) do
    samples
    |> Enum.map(&num(Map.get(&1, key)))
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> nil end)
  end

  defp max_role_mailbox(samples) do
    samples
    |> Enum.flat_map(fn sample -> Map.get(sample, "roles") || [] end)
    |> Enum.map(&num(Map.get(&1, "message_queue_len")))
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> nil end)
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key)
  defp get(_map, _key), do: nil

  defp get_in_ev(record, path) do
    # Delivery records nest the observed/metadata under "evidence".
    base = Map.get(record, "evidence", record)
    get_in_strings(base, path)
  end

  defp get_in_strings(value, []), do: value

  defp get_in_strings(map, [key | rest]) when is_map(map) do
    get_in_strings(Map.get(map, key), rest)
  end

  defp get_in_strings(_value, _path), do: nil

  defp num(value) when is_number(value), do: value
  defp num(_value), do: nil

  defp format_value(value) when is_map(value) do
    "median #{format_number(Map.get(value, :median))} · p95 #{format_number(Map.get(value, :p95))} (n=#{Map.get(value, :count)})"
  end

  defp format_value(value), do: format_number(value)

  defp format_number(nil), do: "n/a"

  # Render whole-magnitude floats as integers to avoid scientific notation in
  # the report (e.g. bits-per-second); keep two decimals for small values.
  defp format_number(value) when is_float(value) and abs(value) >= 1000 do
    value |> round() |> Integer.to_string()
  end

  defp format_number(value) when is_float(value), do: value |> Float.round(2) |> Float.to_string()

  defp format_number(value) when is_integer(value) or is_binary(value) or is_atom(value),
    do: to_string(value)

  defp format_number(_value), do: "n/a"

  defp format_fraction(nil), do: "n/a"
  defp format_fraction(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"
end
