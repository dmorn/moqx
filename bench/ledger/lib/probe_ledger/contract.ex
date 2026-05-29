defmodule ProbeLedger.Contract do
  @moduledoc false

  @schema_version "transport-bench-v1"
  @record_types ~w(run_summary step_summary sample)
  @workload_families ~w(
    path_baseline
    self_pair_calibration
    stream_pressure
    datagram_pressure
    mixed_moqt_shaped
    reference_comparison
    public_relay_interop
  )

  def schema_version, do: @schema_version

  @required_paths [
    ~w(schema_version),
    ~w(record_type),
    ~w(run),
    ~w(run run_id),
    ~w(run started_at),
    ~w(run finished_at),
    ~w(run git_sha),
    ~w(run script),
    ~w(run script_version),
    ~w(run command),
    ~w(run notes),
    ~w(path),
    ~w(path evidence_tier),
    ~w(path path_id),
    ~w(path client host_id),
    ~w(path client provider),
    ~w(path client region),
    ~w(path client instance_class),
    ~w(path client os),
    ~w(path client kernel),
    ~w(path client cpu_model),
    ~w(path client memory_bytes),
    ~w(path client nic_or_network_class),
    ~w(path server host_id),
    ~w(path server provider),
    ~w(path server region),
    ~w(path server instance_class),
    ~w(path server os),
    ~w(path server kernel),
    ~w(path server cpu_model),
    ~w(path server memory_bytes),
    ~w(path server nic_or_network_class),
    ~w(software),
    ~w(software elixir_version),
    ~w(software otp_version),
    ~w(software moqx_version),
    ~w(software quicer_version),
    ~w(software msquic_version),
    ~w(software reference_implementation),
    ~w(software reference_version),
    ~w(profile),
    ~w(profile name),
    ~w(profile alpn),
    ~w(profile datagrams),
    ~w(profile congestion_control),
    ~w(profile pacing),
    ~w(profile settings),
    ~w(workload),
    ~w(workload family),
    ~w(workload direction),
    ~w(workload stream_direction),
    ~w(workload stream_count),
    ~w(workload payload_size_bytes),
    ~w(workload payloads_per_second),
    ~w(workload offered_load_bps),
    ~w(workload datagram_size_bytes),
    ~w(workload datagrams_per_second),
    ~w(workload control_trickle_bps),
    ~w(methodology),
    ~w(methodology warmup_seconds),
    ~w(methodology step_seconds),
    ~w(methodology cooldown_seconds),
    ~w(methodology step_index),
    ~w(methodology step_count),
    ~w(methodology repetition_index),
    ~w(methodology repetition_count),
    ~w(methodology stop_conditions),
    ~w(metrics),
    ~w(metrics handshake_latency_ms),
    ~w(metrics first_byte_latency_ms),
    ~w(metrics offered_load_bps),
    ~w(metrics goodput_bps),
    ~w(metrics send_rate_packets_per_second),
    ~w(metrics send_rate_datagrams_per_second),
    ~w(metrics delivered_datagrams_per_second),
    ~w(metrics datagram_delivery_ratio),
    ~w(metrics datagram_drop_count),
    ~w(metrics datagram_late_count),
    ~w(metrics stream_count),
    ~w(metrics payload_size_bytes),
    ~w(metrics latency_p50_ms),
    ~w(metrics latency_p95_ms),
    ~w(metrics latency_p99_ms),
    ~w(metrics sender_cpu_percent),
    ~w(metrics receiver_cpu_percent),
    ~w(metrics sender_memory_bytes),
    ~w(metrics receiver_memory_bytes),
    ~w(metrics sender_mailbox_depth),
    ~w(metrics receiver_mailbox_depth),
    ~w(metrics send_backpressure_ms),
    ~w(metrics stream_stall_count),
    ~w(metrics control_latency_p99_ms),
    ~w(limits),
    ~w(limits first_break_symptom),
    ~w(limits stopped_by),
    ~w(limits connection_closed),
    ~w(limits protocol_error),
    ~w(limits throughput_plateau),
    ~w(limits latency_explosion),
    ~w(limits mailbox_growth_without_recovery),
    ~w(limits cpu_saturation),
    ~w(limits memory_saturation),
    ~w(limits control_traffic_delayed),
    ~w(errors),
    ~w(errors close_reason),
    ~w(errors error_code),
    ~w(errors message)
  ]

  def validate_records(records) when is_list(records) do
    record_errors =
      records
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {record, index} ->
        record
        |> validate_record_errors()
        |> Enum.map(&Map.put(&1, :record, index))
      end)

    errors = record_errors ++ collection_errors(records)
    warnings = collection_warnings(records)

    %{
      valid?: errors == [],
      errors: errors,
      warnings: warnings
    }
  end

  def validate_record(record) do
    case validate_record_errors(record) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def required_paths, do: @required_paths

  defp validate_record_errors(record) when is_map(record) do
    required_path_errors(record) ++ value_errors(record)
  end

  defp validate_record_errors(_record) do
    [%{path: "$", message: "record must be a JSON object"}]
  end

  defp required_path_errors(record) do
    @required_paths
    |> Enum.reject(&present_path?(record, &1))
    |> Enum.map(fn path ->
      %{path: Enum.join(path, "."), message: "required field is missing"}
    end)
  end

  defp value_errors(record) do
    []
    |> require_value(record, ~w(schema_version), @schema_version)
    |> require_member(record, ~w(record_type), @record_types)
    |> require_member(record, ~w(workload family), @workload_families)
  end

  defp require_value(errors, record, path, expected) do
    case get_path(record, path) do
      {:ok, ^expected} ->
        errors

      {:ok, actual} ->
        [
          %{path: Enum.join(path, "."), message: "expected #{expected}, got #{inspect(actual)}"}
          | errors
        ]

      :error ->
        errors
    end
  end

  defp require_member(errors, record, path, allowed) do
    case get_path(record, path) do
      {:ok, value} ->
        if value in allowed do
          errors
        else
          [
            %{
              path: Enum.join(path, "."),
              message: "expected one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}"
            }
            | errors
          ]
        end

      :error ->
        errors
    end
  end

  defp collection_errors([]), do: [%{path: "$", message: "JSONL file has no records"}]

  defp collection_errors(records) do
    schema_versions =
      records
      |> Enum.map(&value_at(&1, ~w(schema_version)))
      |> Enum.uniq()

    if length(schema_versions) > 1 do
      [%{path: "schema_version", message: "mixed schema versions: #{inspect(schema_versions)}"}]
    else
      []
    end
  end

  defp collection_warnings(records) do
    []
    |> maybe_warn_loopback_only(records)
  end

  defp maybe_warn_loopback_only(warnings, records) do
    tiers =
      records
      |> Enum.map(&value_at(&1, ~w(path evidence_tier)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if tiers == ["loopback_calibration"] do
      [
        %{
          path: "path.evidence_tier",
          message: "loopback calibration only; not real network evidence"
        }
        | warnings
      ]
    else
      warnings
    end
  end

  defp present_path?(record, path) do
    match?({:ok, _value}, get_path(record, path))
  end

  defp value_at(record, path) do
    case get_path(record, path) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp get_path(record, []), do: {:ok, record}

  defp get_path(record, [key | rest]) when is_map(record) do
    case Map.fetch(record, key) do
      {:ok, value} -> get_path(value, rest)
      :error -> :error
    end
  end

  defp get_path(_value, _path), do: :error
end
