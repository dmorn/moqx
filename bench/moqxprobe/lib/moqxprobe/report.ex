defmodule MOQXProbe.Report do
  @moduledoc false

  alias ProbeLedger.Contract

  def render(records, opts \\ []) when is_list(records) do
    validation = Keyword.get_lazy(opts, :validation, fn -> Contract.validate_records(records) end)
    format = Keyword.get(opts, :format, "text")

    [
      title(format),
      "",
      summary(records),
      "",
      runs(records),
      "",
      paths(records),
      "",
      profiles(records),
      "",
      steps(records),
      "",
      limits(records),
      "",
      diagnostics(records),
      "",
      validation(validation)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp title("markdown"), do: "# Transport Benchmark Report"
  defp title(_format), do: "Transport Benchmark Report"

  defp summary(records) do
    schemas = unique(records, ~w(schema_version))
    record_types = unique(records, ~w(record_type))

    [
      "Records: #{length(records)}",
      "Schemas: #{join_values(schemas)}",
      "Record types: #{join_values(record_types)}"
    ]
    |> Enum.join("\n")
  end

  defp runs(records) do
    rows =
      records
      |> Enum.map(& &1["run"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["run_id"])
      |> Enum.map(fn run ->
        "Run: #{value(run["run_id"])} script=#{value(run["script"])} git=#{value(run["git_sha"])} started=#{value(run["started_at"])}"
      end)

    section("Runs", rows)
  end

  defp paths(records) do
    rows =
      records
      |> Enum.map(& &1["path"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&{&1["evidence_tier"], &1["path_id"]})
      |> Enum.map(fn path ->
        "Path: #{value(path["evidence_tier"])} #{value(path["path_id"])} client=#{endpoint(path["client"])} server=#{endpoint(path["server"])}"
      end)

    section("Paths", rows)
  end

  defp profiles(records) do
    rows =
      records
      |> Enum.map(& &1["profile"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&{&1["name"], &1["alpn"], &1["datagrams"]})
      |> Enum.map(fn profile ->
        "Profile: #{value(profile["name"])} alpn=#{value(profile["alpn"])} datagrams=#{value(profile["datagrams"])}"
      end)

    section("Profiles", rows)
  end

  defp steps(records) do
    header =
      [
        pad("step", 24),
        pad("profile", 14),
        pad("seconds", 10),
        pad("goodput", 12),
        pad("send", 12),
        pad("delivered", 12),
        pad("delivery", 10),
        pad("drops", 8),
        "break"
      ]
      |> Enum.join("  ")

    rows =
      Enum.map(records, fn record ->
        metrics = record["metrics"] || %{}
        methodology = record["methodology"] || %{}
        limits = record["limits"] || %{}
        profile = record["profile"] || %{}

        [
          pad(step_name(record), 24),
          pad(value(profile["name"]), 14),
          pad(seconds(methodology["step_seconds"]), 10),
          pad(bps(metrics["goodput_bps"]), 12),
          pad(rate(metrics["send_rate_packets_per_second"]), 12),
          pad(rate(metrics["delivered_datagrams_per_second"]), 12),
          pad(percent(metrics["datagram_delivery_ratio"]), 10),
          pad(value(metrics["datagram_drop_count"]), 8),
          value(limits["first_break_symptom"])
        ]
        |> Enum.join("  ")
      end)

    section("Steps", [header | rows])
  end

  defp limits(records) do
    records
    |> Enum.filter(&limit_record?/1)
    |> Enum.map(&limit_row/1)
    |> case do
      [] -> "Limits\nNo break symptoms recorded."
      rows -> section("Limits", rows)
    end
  end

  defp limit_record?(record) do
    limits = record["limits"] || %{}
    errors = record["errors"] || %{}

    [limits["first_break_symptom"], limits["stopped_by"], errors["message"]]
    |> Enum.any?(&present?/1)
    |> Kernel.||(Enum.any?([limits["connection_closed"], limits["protocol_error"]], &truthy?/1))
  end

  defp limit_row(record) do
    limits = record["limits"] || %{}
    errors = record["errors"] || %{}

    "Limit: #{step_name(record)} first=#{value(limits["first_break_symptom"])} stopped_by=#{value(limits["stopped_by"])} error=#{value(errors["message"])}"
  end

  defp diagnostics(records) do
    rows =
      records
      |> Enum.map(&diagnostic_row/1)
      |> Enum.reject(&is_nil/1)

    section("Diagnostics", rows)
  end

  defp diagnostic_row(%{"diagnostics" => %{"summary" => summary, "process" => process}} = record)
       when is_map(summary) and is_map(process) do
    pending =
      summary["send_completions_pending"] || summary["object_send_completions_pending"] ||
        summary["control_send_completions_pending"]

    completed =
      summary["send_completions"] || summary["object_send_completions"] ||
        summary["control_send_completions"]

    events =
      summary["events_drained"] || summary["stream_receive_events"] ||
        summary["datagram_receive_events"]

    "Diag: #{step_name(record)} sent=#{value(summary["bytes_sent"])} recv=#{value(summary["bytes_received"])} send_done=#{value(completed)} pending=#{value(pending)} events=#{value(events)} mailbox=#{value(process["message_queue_len"])}/#{value(process["message_queue_len_peak"])}"
  end

  defp diagnostic_row(_record), do: nil

  defp validation(%{valid?: true, warnings: []}), do: "Validation\nOK"

  defp validation(validation) do
    errors = Enum.map(validation.errors, &validation_line("error", &1))
    warnings = Enum.map(validation.warnings, &validation_line("warning", &1))
    section("Validation", errors ++ warnings)
  end

  defp validation_line(kind, item) do
    record = if Map.has_key?(item, :record), do: " record=#{item.record}", else: ""
    "#{kind}:#{record} #{item.path}: #{item.message}"
  end

  defp section(_name, []), do: ""
  defp section(name, rows), do: Enum.join([name | rows], "\n")

  defp unique(records, path) do
    records
    |> Enum.map(&value_at(&1, path))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp value_at(record, []), do: record

  defp value_at(record, [key | rest]) when is_map(record) do
    case Map.fetch(record, key) do
      {:ok, value} -> value_at(value, rest)
      :error -> nil
    end
  end

  defp value_at(_value, _path), do: nil

  defp endpoint(nil), do: "n/a"

  defp endpoint(endpoint),
    do:
      "#{value(endpoint["host_id"])}@#{value(endpoint["provider"])}/#{value(endpoint["region"])}"

  defp step_name(record) do
    workload = record["workload"] || %{}
    profile = record["profile"] || %{}
    settings = profile["settings"] || %{}

    value =
      first_present([
        workload["step"],
        settings["workload"],
        workload["family"]
      ])

    value(value)
  end

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp seconds(value) when is_number(value),
    do: :io_lib.format("~.3fs", [value * 1.0]) |> IO.iodata_to_binary()

  defp seconds(_value), do: "n/a"

  defp bps(value) when is_number(value) and value >= 1_000_000_000,
    do: float("#{value / 1_000_000_000}", "Gbps")

  defp bps(value) when is_number(value) and value >= 1_000_000,
    do: float("#{value / 1_000_000}", "Mbps")

  defp bps(value) when is_number(value) and value >= 1_000, do: float("#{value / 1_000}", "Kbps")
  defp bps(value) when is_number(value), do: "#{round(value)} bps"
  defp bps(_value), do: "n/a"

  defp rate(value) when is_number(value) and value >= 1_000_000,
    do: float("#{value / 1_000_000}", "M/s")

  defp rate(value) when is_number(value) and value >= 1_000, do: float("#{value / 1_000}", "k/s")
  defp rate(value) when is_number(value), do: float("#{value}", "/s")
  defp rate(_value), do: "n/a"

  defp percent(value) when is_number(value),
    do: (:io_lib.format("~.2f", [value * 100.0]) |> IO.iodata_to_binary()) <> "%"

  defp percent(_value), do: "n/a"

  defp float(raw, suffix) do
    {value, ""} = Float.parse(raw)
    (:io_lib.format("~.2f", [value]) |> IO.iodata_to_binary()) <> " " <> suffix
  end

  defp value(value) when value in [nil, :null], do: "n/a"

  defp value(value) when is_float(value),
    do: :io_lib.format("~.3f", [value]) |> IO.iodata_to_binary()

  defp value(value), do: to_string(value)

  defp join_values([]), do: "n/a"
  defp join_values(values), do: Enum.map_join(values, ", ", &value/1)

  defp present?(value), do: value not in [nil, :null, ""]
  defp truthy?(value), do: value == true

  defp pad(value, size) do
    value
    |> to_string()
    |> String.slice(0, size)
    |> String.pad_trailing(size)
  end
end
