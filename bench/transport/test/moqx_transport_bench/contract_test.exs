defmodule MOQX.TransportBench.ContractTest do
  use ExUnit.Case, async: true

  alias MOQX.TransportBench.Contract

  test "accepts a complete transport-bench-v1 record" do
    validation = Contract.validate_records([valid_record()])

    assert validation.valid?
    assert validation.errors == []

    assert [
             %{
               path: "path.evidence_tier",
               message: "loopback calibration only; not real network evidence"
             }
           ] =
             validation.warnings
  end

  test "reports missing required fields with record numbers" do
    record =
      valid_record()
      |> pop_in(["metrics", "goodput_bps"])
      |> elem(1)

    validation = Contract.validate_records([record])

    refute validation.valid?

    assert %{record: 1, path: "metrics.goodput_bps", message: "required field is missing"} in validation.errors
  end

  test "rejects mixed schema versions" do
    records = [
      valid_record(),
      valid_record(%{"schema_version" => "transport-bench-v2"})
    ]

    validation = Contract.validate_records(records)

    refute validation.valid?
    assert Enum.any?(validation.errors, &(&1.path == "schema_version"))
  end

  defp valid_record(overrides \\ %{}) do
    %{
      "schema_version" => "transport-bench-v1",
      "record_type" => "step_summary",
      "run" => %{
        "run_id" => "run-1",
        "started_at" => "2026-05-20T00:00:00Z",
        "finished_at" => "2026-05-20T00:00:01Z",
        "git_sha" => "abcdef0",
        "script" => "mix moqx.transport.self_pair",
        "script_version" => "v1",
        "command" => "mix moqx.transport.self_pair --profile draft_14",
        "notes" => nil
      },
      "path" => %{
        "evidence_tier" => "loopback_calibration",
        "path_id" => "loopback",
        "client" => endpoint("client"),
        "server" => endpoint("server")
      },
      "software" => %{
        "elixir_version" => "1.19.0",
        "otp_version" => "28",
        "moqx_version" => "0.7.1",
        "quicer_version" => "0.0.0",
        "msquic_version" => nil,
        "reference_implementation" => nil,
        "reference_version" => nil
      },
      "profile" => %{
        "name" => "draft_14",
        "alpn" => "moq-00",
        "datagrams" => true,
        "congestion_control" => nil,
        "pacing" => nil,
        "settings" => %{}
      },
      "workload" => %{
        "family" => "self_pair_calibration",
        "direction" => "client_to_server",
        "stream_direction" => "unidirectional",
        "stream_count" => 1,
        "payload_size_bytes" => 1200,
        "payloads_per_second" => nil,
        "offered_load_bps" => nil,
        "datagram_size_bytes" => nil,
        "datagrams_per_second" => nil,
        "control_trickle_bps" => nil,
        "step" => "stream_pressure"
      },
      "methodology" => %{
        "warmup_seconds" => 0,
        "step_seconds" => 1.0,
        "cooldown_seconds" => 0,
        "step_index" => 1,
        "step_count" => 1,
        "repetition_index" => 1,
        "repetition_count" => 1,
        "stop_conditions" => []
      },
      "metrics" => %{
        "handshake_latency_ms" => nil,
        "first_byte_latency_ms" => nil,
        "offered_load_bps" => nil,
        "goodput_bps" => 1_000_000.0,
        "send_rate_packets_per_second" => 100.0,
        "send_rate_datagrams_per_second" => nil,
        "delivered_datagrams_per_second" => nil,
        "datagram_delivery_ratio" => nil,
        "datagram_drop_count" => nil,
        "datagram_late_count" => nil,
        "stream_count" => 1,
        "payload_size_bytes" => 1200,
        "latency_p50_ms" => nil,
        "latency_p95_ms" => nil,
        "latency_p99_ms" => nil,
        "sender_cpu_percent" => nil,
        "receiver_cpu_percent" => nil,
        "sender_memory_bytes" => nil,
        "receiver_memory_bytes" => nil,
        "sender_mailbox_depth" => nil,
        "receiver_mailbox_depth" => nil,
        "send_backpressure_ms" => nil,
        "stream_stall_count" => 0,
        "control_latency_p99_ms" => nil
      },
      "limits" => %{
        "first_break_symptom" => nil,
        "stopped_by" => nil,
        "connection_closed" => false,
        "protocol_error" => false,
        "throughput_plateau" => false,
        "latency_explosion" => false,
        "mailbox_growth_without_recovery" => false,
        "cpu_saturation" => false,
        "memory_saturation" => false,
        "control_traffic_delayed" => false
      },
      "errors" => %{
        "close_reason" => nil,
        "error_code" => nil,
        "message" => nil
      }
    }
    |> deep_merge(overrides)
  end

  defp endpoint(role) do
    %{
      "host_id" => role,
      "provider" => "local",
      "region" => nil,
      "instance_class" => nil,
      "os" => "darwin",
      "kernel" => nil,
      "cpu_model" => nil,
      "memory_bytes" => nil,
      "nic_or_network_class" => "loopback"
    }
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
