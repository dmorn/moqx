defmodule MOQX.TransportBench.ReferenceComparisonTest do
  use ExUnit.Case, async: true

  alias MOQX.TransportBench.Contract
  alias MOQX.TransportBench.JSONL
  alias MOQX.TransportBench.ReferenceComparison

  test "emits a valid reference comparison record from quicprobe JSON" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference.jsonl")
    args_path = Path.join(dir, "quicprobe.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path)

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--alpn",
        "moqx-test",
        "--stream-count",
        "2",
        "--payload-size",
        "256",
        "--payload-count",
        "4",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["workload"]["family"] == "reference_comparison"
    assert record["workload"]["stream_direction"] == "bidirectional"
    assert record["workload"]["stream_count"] == 2
    assert record["workload"]["payload_size_bytes"] == 256
    assert record["metrics"]["bytes_sent"] == 2048
    assert record["metrics"]["bytes_received"] == 2048
    assert record["metrics"]["goodput_bps"] == 32_000_000.0
    assert record["software"]["reference_implementation"] == "quic-go"
    assert record["software"]["reference_version"] == "v0.50.1"
    assert record["profile"]["settings"]["topology"] == "reference-client-to-reference-server"
    assert record["profile"]["settings"]["workload"] == "stream_pressure"
    assert record["profile"]["settings"]["stream_scheduling"] == "concurrent"
    assert record["profile"]["settings"]["server_implementation"] == "quicprobe"

    args = File.read!(args_path)
    assert args =~ "client"
    assert args =~ "--json"
    assert args =~ "--addr 127.0.0.1:4433"
    assert args =~ "--workload stream_pressure"
    assert args =~ "--stream-count 2"
    assert args =~ "--payload-size 256"
    assert args =~ "--payload-count 4"
  end

  test "emits a valid reference client to MOQX listener record from quicprobe JSON" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-client-moqx-listener.jsonl")
    args_path = Path.join(dir, "quicprobe-listener.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path)

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-moqx-listener",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--stream-count",
        "2",
        "--payload-size",
        "256",
        "--payload-count",
        "4",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-client-listener-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["workload"]["family"] == "reference_comparison"
    assert record["workload"]["tool"] == "quicprobe"
    assert record["workload"]["topology"] == "reference-client-to-moqx-listener"
    assert record["profile"]["settings"]["topology"] == "reference-client-to-moqx-listener"
    assert record["profile"]["settings"]["workload"] == "stream_pressure"
    assert record["profile"]["settings"]["client_implementation"] == "quicprobe"
    assert record["profile"]["settings"]["server_implementation"] == "moqx"
    assert record["profile"]["settings"]["stream_scheduling"] == "concurrent"
    assert record["metrics"]["bytes_sent"] == 2048
    assert record["metrics"]["bytes_received"] == 2048

    args = File.read!(args_path)
    assert args =~ "client"
    assert args =~ "--json"
    assert args =~ "--addr 127.0.0.1:4433"
    assert args =~ "--workload stream_pressure"
    assert args =~ "--stream-count 2"
    assert args =~ "--payload-size 256"
    assert args =~ "--payload-count 4"
  end

  test "emits a valid datagram pressure record from quicprobe JSON" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-datagram.jsonl")
    args_path = Path.join(dir, "quicprobe-datagram.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path, datagram_quicprobe_json())

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--datagram-size",
        "64",
        "--datagram-count",
        "4",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-datagram-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["profile"]["datagrams"] == true
    assert record["profile"]["settings"]["workload"] == "datagram_pressure"
    assert record["profile"]["settings"]["datagram_mode"] == "burst"
    assert record["profile"]["settings"]["stream_scheduling"] == :null
    assert record["workload"]["stream_count"] == :null
    assert record["workload"]["datagram_size_bytes"] == 64
    assert record["workload"]["datagrams_per_second"] == 4000.0
    assert record["metrics"]["bytes_sent"] == 256
    assert record["metrics"]["bytes_received"] == 192
    assert record["metrics"]["send_rate_datagrams_per_second"] == 4000.0
    assert record["metrics"]["delivered_datagrams_per_second"] == 1500.0
    assert record["metrics"]["datagram_delivery_ratio"] == 0.75
    assert record["metrics"]["datagram_drop_count"] == 1
    assert record["metrics"]["latency_p50_ms"] == 0.2
    assert record["limits"]["first_break_symptom"] == "datagram_delivery_loss"
    assert record["limits"]["stopped_by"] == "datagram_delivery_loss"
    assert record["errors"]["message"] == :null

    args = File.read!(args_path)
    assert args =~ "--workload datagram_pressure"
    assert args =~ "--datagram-size 64"
    assert args =~ "--datagram-count 4"
  end

  test "emits paced datagram pressure fields and threshold stop condition" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-paced-datagram.jsonl")
    args_path = Path.join(dir, "quicprobe-paced-datagram.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path, paced_datagram_quicprobe_json())

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--datagram-size",
        "64",
        "--datagram-rate",
        "5",
        "--duration-seconds",
        "2",
        "--delivery-threshold",
        "0.95",
        "--offered-rate-tolerance",
        "0.9",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-paced-datagram-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["profile"]["settings"]["datagram_mode"] == "paced"
    assert record["profile"]["settings"]["delivery_threshold"] == 0.95
    assert record["profile"]["settings"]["offered_rate_tolerance"] == 0.9
    assert record["profile"]["pacing"] == "paced"
    assert record["workload"]["datagrams_per_second"] == 5.0
    assert record["workload"]["offered_load_bps"] == 2560.0
    assert record["methodology"]["active_send_seconds"] == 2.1
    assert record["methodology"]["target_send_seconds"] == 2
    assert record["methodology"]["scheduled_send_span_seconds"] == 1.8
    assert record["methodology"]["total_observation_seconds"] == 2
    assert record["metrics"]["offered_load_bps"] == 2560.0
    assert record["metrics"]["offered_rate_ratio"] == 1.0
    assert record["metrics"]["send_duration_ms"] == 2100.0
    assert record["metrics"]["target_send_duration_ms"] == 2000.0
    assert record["metrics"]["scheduled_send_span_ms"] == 1800.0
    assert record["metrics"]["send_pacing_late_count"] == 2
    assert record["metrics"]["send_pacing_lag_p99_ms"] == 0.8
    assert record["metrics"]["send_datagram_call_slow_count"] == 3
    assert record["metrics"]["send_datagram_call_slow_threshold_ms"] == 0.2
    assert record["metrics"]["send_datagram_call_total_ms"] == 4.4
    assert record["metrics"]["send_datagram_call_p99_ms"] == 1.4
    assert record["metrics"]["send_datagram_call_p999_ms"] == 1.9
    assert record["metrics"]["send_datagram_call_max_ms"] == 2.0
    assert record["metrics"]["datagram_late_count"] == 2
    assert record["metrics"]["datagram_delivery_ratio"] == 0.9
    assert record["metrics"]["datagram_drop_count"] == 1
    assert record["limits"]["first_break_symptom"] == "datagram_delivery_loss"

    args = File.read!(args_path)
    assert args =~ "--workload datagram_pressure"
    assert args =~ "--datagram-size 64"
    assert args =~ "--datagram-rate 5"
    assert args =~ "--duration-seconds 2"
    assert args =~ "--offered-rate-tolerance 0.9"
    assert args =~ "--timeout 7s"
  end

  test "emits a mixed MOQT-shaped reference comparison record" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-mixed.jsonl")
    args_path = Path.join(dir, "quicprobe-mixed.args")
    fake_quicprobe = fake_quicprobe_command(dir, args_path, mixed_quicprobe_json())

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--workload",
        "mixed_moqt_shaped",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--stream-count",
        "2",
        "--payload-size",
        "512",
        "--payload-count",
        "2",
        "--control-payload-size",
        "32",
        "--control-message-count",
        "3",
        "--control-rate",
        "2",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-mixed-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["profile"]["settings"]["workload"] == "mixed_moqt_shaped"
    assert record["profile"]["settings"]["stream_scheduling"] == "mixed_control_bidi_object_uni"
    assert record["workload"]["family"] == "mixed_moqt_shaped"
    assert record["workload"]["stream_direction"] == "mixed"
    assert record["workload"]["stream_count"] == 2
    assert record["workload"]["payload_size_bytes"] == 512
    assert record["workload"]["datagram_size_bytes"] == :null
    assert record["workload"]["datagrams_per_second"] == :null
    assert record["workload"]["control_trickle_bps"] == 512.0
    assert record["metrics"]["bytes_sent"] == 2144
    assert record["metrics"]["bytes_received"] == 96
    assert record["metrics"]["datagram_delivery_ratio"] == :null
    assert record["metrics"]["control_latency_p99_ms"] == 3.0
    assert record["limits"]["control_traffic_delayed"] == false
    assert record["limits"]["first_break_symptom"] == :null

    args = File.read!(args_path)
    assert args =~ "--workload mixed_moqt_shaped"
    assert args =~ "--stream-count 2"
    assert args =~ "--payload-size 512"
    assert args =~ "--payload-count 2"
    assert args =~ "--control-payload-size 32"
    assert args =~ "--control-message-count 3"
    assert args =~ "--control-rate 2"
  end

  test "marks paced datagram results invalid when the generator misses the target offered rate" do
    dir = tmp_dir()
    output_path = Path.join(dir, "reference-paced-invalid.jsonl")

    fake_quicprobe =
      fake_quicprobe_command(
        dir,
        Path.join(dir, "quicprobe-paced-invalid.args"),
        paced_datagram_quicprobe_json(offered_rate_ratio: 0.8, offered_rate_valid: false)
      )

    ReferenceComparison.main(
      [
        "--topology",
        "reference-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--datagram-size",
        "64",
        "--datagram-rate",
        "5",
        "--duration-seconds",
        "2",
        "--delivery-threshold",
        "0.95",
        "--offered-rate-tolerance",
        "0.95",
        "--quicprobe-command",
        fake_quicprobe,
        "--output",
        output_path,
        "--run-id",
        "reference-paced-invalid-test"
      ],
      script: "test reference-comparison"
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?
    assert record["limits"]["first_break_symptom"] == "tool_output_invalid"
    assert record["limits"]["stopped_by"] == "reference_comparison_invalid_measurement"
    assert record["limits"]["protocol_error"] == true
    assert record["errors"]["message"] =~ "offered rate below tolerance"
    assert record["errors"]["message"] =~ "0.8 < 0.95"
  end

  test "records MOQX datagram send errors without crashing or losing requested load metadata" do
    dir = tmp_dir()
    output_path = Path.join(dir, "moqx-datagram-send-error.jsonl")

    ReferenceComparison.main(
      [
        "--topology",
        "moqx-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--datagram-size",
        "1193",
        "--datagram-rate",
        "5",
        "--duration-seconds",
        "2",
        "--output",
        output_path,
        "--run-id",
        "moqx-datagram-send-error-test"
      ],
      script: "test reference-comparison",
      transport_backend: __MODULE__.DatagramSendErrorTransport
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["workload"]["topology"] == "moqx-client-to-reference-server"
    assert record["workload"]["datagram_size_bytes"] == 1193
    assert record["workload"]["datagrams_per_second"] == 5.0
    assert record["workload"]["offered_load_bps"] == 47_720.0
    assert record["metrics"]["payload_size_bytes"] == 1193
    assert record["metrics"]["offered_load_bps"] == 47_720.0
    assert record["metrics"]["bytes_sent"] == 0
    assert record["metrics"]["bytes_received"] == 0
    assert record["metrics"]["receiver_mailbox_depth"] == 0
    assert record["limits"]["first_break_symptom"] == "datagram_send_error"
    assert record["limits"]["stopped_by"] == "datagram_send_error"
    assert record["limits"]["protocol_error"] == true
    assert record["errors"]["message"] == "moqx datagram send failed: invalid_parameter"
    refute record["errors"]["message"] =~ "MatchError"

    assert record["errors"]["details"] == %{
             "phase" => "send_datagram",
             "reason" => "invalid_parameter",
             "datagram_sequence" => 1,
             "datagrams_offered" => 10,
             "datagrams_accepted" => 0,
             "datagram_size_bytes" => 1193,
             "target_datagrams_per_second" => 5.0,
             "target_duration_seconds" => 2,
             "offered_load_bps" => 47_720.0,
             "topology" => "moqx-client-to-reference-server"
           }

    assert record["diagnostics"]["process"]["message_queue_len"] == 0
    assert record["diagnostics"]["process"]["message_queue_len_peak"] >= 0
    assert record["diagnostics"]["summary"]["datagrams_accepted"] == 0
    assert record["diagnostics"]["summary"]["datagrams_received"] == 0
    assert record["diagnostics"]["summary"]["send_error"] == "invalid_parameter"
  end

  test "records successful near-limit MOQX datagram delivery" do
    dir = tmp_dir()
    output_path = Path.join(dir, "moqx-near-limit-datagram.jsonl")

    ReferenceComparison.main(
      [
        "--topology",
        "moqx-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--datagram-size",
        "1192",
        "--datagram-count",
        "2",
        "--output",
        output_path,
        "--run-id",
        "moqx-near-limit-datagram-test"
      ],
      script: "test reference-comparison",
      transport_backend: __MODULE__.DatagramEchoTransport
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["workload"]["topology"] == "moqx-client-to-reference-server"
    assert record["workload"]["datagram_size_bytes"] == 1192
    assert record["metrics"]["payload_size_bytes"] == 1192
    assert record["metrics"]["bytes_sent"] == 2384
    assert record["metrics"]["bytes_received"] == 2384
    assert record["metrics"]["datagram_delivery_ratio"] == 1.0
    assert record["metrics"]["datagram_drop_count"] == 0
    assert record["metrics"]["receiver_mailbox_depth"] == 0
    assert record["limits"]["first_break_symptom"] == :null
    assert record["errors"]["message"] == :null

    assert record["diagnostics"]["version"] == "moqx-client-datagram-diagnostics-v1"
    assert record["diagnostics"]["process"]["message_queue_len"] == 0
    assert record["diagnostics"]["process"]["message_queue_len_peak"] >= 0
    assert record["diagnostics"]["summary"]["datagrams_accepted"] == 2
    assert record["diagnostics"]["summary"]["datagrams_received"] == 2
    assert record["diagnostics"]["summary"]["datagrams_missing"] == 0
    assert record["diagnostics"]["summary"]["bytes_sent"] == 2384
    assert record["diagnostics"]["summary"]["bytes_received"] == 2384
    assert record["diagnostics"]["summary"]["datagram_receive_events"] == 2
    assert is_number(record["diagnostics"]["summary"]["active_send_duration_ms"])
    assert is_number(record["diagnostics"]["summary"]["active_receive_duration_ms"])
    assert is_number(record["diagnostics"]["summary"]["observation_duration_ms"])

    assert record["diagnostics"]["summary"]["receive_loop_stop_reason"] ==
             "expected_datagrams_received"

    assert record["diagnostics"]["summary"]["receive_errors"] == 0

    assert [
             %{
               "sample_index" => 1,
               "phase" => "start",
               "datagrams_accepted" => 0,
               "datagrams_received" => 0,
               "accepted_delta" => 0,
               "received_delta" => 0
             }
             | _
           ] = record["diagnostics"]["cadence"]

    final_cadence = List.last(record["diagnostics"]["cadence"])
    assert final_cadence["phase"] == "final"
    assert final_cadence["datagrams_accepted"] == 2
    assert final_cadence["datagrams_received"] == 2
    assert final_cadence["delivery_gap_to_accepted"] == 0
  end

  test "keeps paced MOQX datagram sending on schedule when no receive events are pending" do
    dir = tmp_dir()
    output_path = Path.join(dir, "moqx-paced-datagram-silent-peer.jsonl")

    ReferenceComparison.main(
      [
        "--topology",
        "moqx-client-to-reference-server",
        "--workload",
        "datagram_pressure",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--datagram-size",
        "64",
        "--datagram-rate",
        "3000",
        "--duration-seconds",
        "1",
        "--timeout-seconds",
        "1",
        "--timeout-margin-seconds",
        "1",
        "--output",
        output_path,
        "--run-id",
        "moqx-paced-datagram-silent-peer-test"
      ],
      script: "test reference-comparison",
      transport_backend: __MODULE__.DatagramSilentTransport
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["profile"]["settings"]["datagram_mode"] == "paced"
    assert record["workload"]["datagrams_per_second"] == 3000.0
    assert record["metrics"]["offered_rate_ratio"] >= 0.95
    assert record["metrics"]["send_rate_datagrams_per_second"] >= 2850.0
    assert record["metrics"]["target_send_duration_ms"] == 1000.0
    assert_in_delta record["metrics"]["scheduled_send_span_ms"], 999.666, 0.1
    assert is_integer(record["metrics"]["send_pacing_late_count"])
    assert is_number(record["metrics"]["send_pacing_lag_p99_ms"])
    assert is_number(record["metrics"]["send_datagram_call_total_ms"])
    assert is_number(record["metrics"]["send_payload_encode_call_total_ms"])
    assert is_number(record["metrics"]["send_datagram_outer_call_total_ms"])
    assert is_number(record["metrics"]["send_datagram_wrapper_overhead_total_ms"])
    assert is_number(record["metrics"]["send_loop_overrun_ms"])
    assert is_number(record["metrics"]["send_loop_unmeasured_overhead_ms"])
    assert is_number(record["metrics"]["send_loop_residual_overhead_ms"])
    assert record["metrics"]["datagram_delivery_ratio"] == 0.0
    assert record["limits"]["first_break_symptom"] == "datagram_delivery_loss"
    refute record["limits"]["first_break_symptom"] == "tool_output_invalid"

    summary = record["diagnostics"]["summary"]
    assert summary["datagrams_accepted"] == 3000
    assert summary["datagrams_received"] == 0
    assert summary["datagram_send_errors"] == 0
    assert summary["send_pacing_late_count"] == record["metrics"]["send_pacing_late_count"]
    assert summary["send_payload_encode_call_ms"]["count"] == 3000
    assert summary["send_datagram_outer_call_ms"]["count"] == 3000
    assert is_number(summary["send_datagram_wrapper_overhead_ms"])
    assert is_number(summary["send_loop_unmeasured_overhead_ms"])
    assert is_number(summary["send_loop_residual_overhead_ms"])
  end

  test "records mixed MOQT-shaped MOQX client pressure" do
    dir = tmp_dir()
    output_path = Path.join(dir, "moqx-mixed.jsonl")

    ReferenceComparison.main(
      [
        "--topology",
        "moqx-client-to-reference-server",
        "--workload",
        "mixed_moqt_shaped",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--stream-count",
        "2",
        "--payload-size",
        "64",
        "--payload-count",
        "2",
        "--control-payload-size",
        "16",
        "--control-message-count",
        "2",
        "--control-rate",
        "100",
        "--output",
        output_path,
        "--run-id",
        "moqx-mixed-test"
      ],
      script: "test reference-comparison",
      transport_backend: __MODULE__.MixedEchoTransport
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["profile"]["settings"]["workload"] == "mixed_moqt_shaped"
    assert record["profile"]["settings"]["stream_scheduling"] == "mixed_control_bidi_object_uni"
    assert record["workload"]["family"] == "mixed_moqt_shaped"
    assert record["workload"]["tool"] == "moqx"
    assert record["workload"]["stream_direction"] == "mixed"
    assert record["workload"]["stream_count"] == 2
    assert record["workload"]["payload_size_bytes"] == 64
    assert record["workload"]["datagram_size_bytes"] == :null
    assert record["workload"]["datagrams_per_second"] == :null
    assert record["workload"]["control_trickle_bps"] == 12_800.0
    assert record["metrics"]["stream_count"] == 2
    assert record["metrics"]["payload_size_bytes"] == 64
    assert record["metrics"]["bytes_sent"] == 288
    assert record["metrics"]["bytes_received"] == 32
    assert record["metrics"]["datagram_delivery_ratio"] == :null
    assert record["metrics"]["sender_mailbox_depth"] == 0
    assert is_number(record["metrics"]["control_latency_p99_ms"])
    assert record["limits"]["first_break_symptom"] == :null
    assert record["errors"]["message"] == :null

    assert record["diagnostics"]["process"]["message_queue_len"] == 0
    assert record["diagnostics"]["process"]["message_queue_len_peak"] >= 0

    assert record["diagnostics"]["summary"]["object_payloads_accepted"] == 4
    assert record["diagnostics"]["summary"]["object_send_completions"] == 4
    assert record["diagnostics"]["summary"]["object_send_completions_pending"] == 0
    assert record["diagnostics"]["summary"]["bytes_sent"] == 288
    assert record["diagnostics"]["summary"]["bytes_received"] == 32
    assert record["diagnostics"]["summary"]["events_drained"] >= 6
    assert record["diagnostics"]["summary"]["completion_drain_events"] == 1
    assert record["diagnostics"]["summary"]["control_data_events"] == 2
  end

  test "records structured diagnostics when MOQX bidirectional echo closes early" do
    dir = tmp_dir()
    output_path = Path.join(dir, "moqx-peer-shutdown.jsonl")

    ReferenceComparison.main(
      [
        "--topology",
        "moqx-client-to-reference-server",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--stream-direction",
        "bidirectional",
        "--stream-count",
        "2",
        "--payload-size",
        "256",
        "--payload-count",
        "4",
        "--output",
        output_path,
        "--run-id",
        "moqx-peer-shutdown-test"
      ],
      script: "test reference-comparison",
      transport_backend: __MODULE__.PeerShutdownTransport
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["limits"]["first_break_symptom"] == "stream_closed_before_expected_bytes"
    assert record["limits"]["stopped_by"] == "stream_closed_before_expected_bytes"
    assert record["limits"]["protocol_error"] == true
    assert record["errors"]["message"] =~ "reason=peer_send_shutdown"
    assert record["errors"]["details"]["bytes_expected"] == 1024
    assert record["metrics"]["bytes_sent"] == 2048
    assert record["metrics"]["bytes_received"] == 0

    diagnostics = record["diagnostics"]
    assert diagnostics["version"] == "stream-pressure-diagnostics-v1"
    assert diagnostics["summary"]["streams_opened"] == 2
    assert diagnostics["summary"]["streams_failed"] == 1
    assert diagnostics["summary"]["bytes_sent"] == 2048
    assert diagnostics["summary"]["bytes_received"] == 0

    assert [
             %{"phase" => "echo_failed", "error" => "peer_send_shutdown"},
             %{"phase" => "receiving_echo"}
           ] = diagnostics["streams"]
  end

  test "records stream-pressure runtime diagnostics for MOQX bidirectional echo" do
    dir = tmp_dir()
    output_path = Path.join(dir, "moqx-stream-diagnostics.jsonl")

    ReferenceComparison.main(
      [
        "--topology",
        "moqx-client-to-reference-server",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--stream-direction",
        "bidirectional",
        "--stream-count",
        "2",
        "--payload-size",
        "64",
        "--payload-count",
        "2",
        "--output",
        output_path,
        "--run-id",
        "moqx-stream-diagnostics-test"
      ],
      script: "test reference-comparison",
      transport_backend: __MODULE__.MixedEchoTransport
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    diagnostics = record["diagnostics"]
    assert diagnostics["version"] == "stream-pressure-diagnostics-v1"
    assert diagnostics["summary"]["payloads_accepted"] == 4
    assert diagnostics["summary"]["payloads_completed"] == 4
    assert diagnostics["summary"]["send_completions"] == 4
    assert diagnostics["summary"]["send_completions_pending"] == 0
    assert diagnostics["summary"]["events_drained"] >= 8
    assert diagnostics["summary"]["stream_data_events"] == 4
    assert diagnostics["summary"]["send_completed_events"] == 4
    assert is_number(diagnostics["summary"]["active_send_duration_ms"])
    assert is_number(diagnostics["summary"]["active_echo_receive_duration_ms"])

    assert diagnostics["process"]["message_queue_len_samples"] > 0

    assert [%{"sample_index" => 1, "message_queue_len" => first_sample} | _] =
             diagnostics["process"]["message_queue_len_sample_points"]

    assert is_integer(first_sample)

    assert Enum.all?(diagnostics["streams"], fn stream ->
             stream["completion_status"] == "completed" and
               stream["send_completed"] == 2 and
               stream["send_completions_pending"] == 0
           end)
  end

  test "records stream-pressure pump tuning knobs" do
    dir = tmp_dir()
    output_path = Path.join(dir, "moqx-stream-pump-tuning.jsonl")

    ReferenceComparison.main(
      [
        "--topology",
        "moqx-client-to-reference-server",
        "--server",
        "127.0.0.1",
        "--port",
        "4433",
        "--ca",
        "/tmp/ca.pem",
        "--servername",
        "localhost",
        "--stream-direction",
        "bidirectional",
        "--stream-count",
        "1",
        "--stream-send-window",
        "1",
        "--stream-event-batch-size",
        "4",
        "--stream-diagnostics-sampling",
        "final",
        "--payload-size",
        "64",
        "--payload-count",
        "3",
        "--output",
        output_path,
        "--run-id",
        "moqx-stream-pump-tuning-test"
      ],
      script: "test reference-comparison",
      transport_backend: __MODULE__.MixedEchoTransport
    )

    assert {:ok, [record]} = output_path |> File.read!() |> JSONL.parse()
    assert Contract.validate_records([record]).valid?

    assert record["profile"]["settings"]["stream_send_window"] == 1
    assert record["profile"]["settings"]["stream_event_batch_size"] == 4
    assert record["profile"]["settings"]["stream_diagnostics_sampling"] == "final"

    diagnostics = record["diagnostics"]
    assert diagnostics["summary"]["stream_send_window"] == 1
    assert diagnostics["summary"]["stream_event_batch_size"] == 4
    assert diagnostics["summary"]["stream_diagnostics_sampling"] == "final"
    assert diagnostics["summary"]["payloads_completed"] == 3
    assert diagnostics["summary"]["send_completions_pending"] == 0
    assert diagnostics["summary"]["stream_send_accepted"] == 3
    assert diagnostics["summary"]["stream_send_bytes_accepted"] == 192
    assert diagnostics["summary"]["stream_send_errors"] == 0
    assert diagnostics["summary"]["stream_data_bytes_received"] == 192
    assert diagnostics["summary"]["send_stream_call_ms"]["count"] == 3
    assert is_number(diagnostics["summary"]["send_stream_call_ms"]["total"])
    assert diagnostics["summary"]["receive_event_call_ms"]["count"] > 0
    assert is_number(diagnostics["summary"]["receive_event_call_ms"]["total"])
    assert hd(diagnostics["streams"])["send_stream_call_ms"]["count"] == 3
    assert is_number(record["metrics"]["send_stream_call_total_ms"])
    assert is_integer(diagnostics["process"]["message_queue_len"])
    refute Map.has_key?(diagnostics["process"], "message_queue_len_sample_points")
  end

  defp fake_quicprobe_command(dir, args_path) do
    fake_quicprobe_command(dir, args_path, stream_quicprobe_json())
  end

  defp fake_quicprobe_command(dir, args_path, json) do
    script_path = Path.join(dir, "fake-quicprobe")

    File.write!(script_path, """
    #!/usr/bin/env sh
    printf '%s' "$*" > '#{args_path}'
    cat <<'JSON'
    #{json}
    JSON
    """)

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp stream_quicprobe_json do
    """
    {
      "schema_version": "quicprobe-v1",
      "record_type": "client_run",
      "tool": "quicprobe",
      "reference_implementation": "quic-go",
      "reference_version": "v0.50.1",
      "started_at": "2026-05-21T10:15:13Z",
      "finished_at": "2026-05-21T10:15:14Z",
      "remote_addr": "127.0.0.1:4433",
      "alpn": "moqx-test",
      "stream_direction": "bidirectional",
      "stream_count": 2,
      "payload_size_bytes": 256,
      "payload_count": 4,
      "bytes_sent": 2048,
      "bytes_received": 2048,
      "handshake_latency_ms": 6.5,
      "first_byte_latency_ms": 0.4,
      "application_duration_ms": 0.512,
      "goodput_bps": 32000000.0,
      "stream_latency_ms": {
        "p50": 0.4,
        "p95": 0.5,
        "p99": 0.5
      }
    }
    """
  end

  defp datagram_quicprobe_json do
    """
    {
      "schema_version": "quicprobe-v1",
      "record_type": "client_run",
      "tool": "quicprobe",
      "reference_implementation": "quic-go",
      "reference_version": "v0.50.1",
      "started_at": "2026-05-21T10:15:13Z",
      "finished_at": "2026-05-21T10:15:14Z",
      "remote_addr": "127.0.0.1:4433",
      "alpn": "moqx-test",
      "workload": "datagram_pressure",
      "payload_size_bytes": 64,
      "datagram_size_bytes": 64,
      "datagram_count": 4,
      "datagram_mode": "burst",
      "datagrams_offered": 4,
      "datagrams_accepted": 4,
      "datagrams_received": 3,
      "datagram_delivery_ratio": 0.75,
      "datagram_drop_count": 1,
      "bytes_sent": 256,
      "bytes_received": 192,
      "handshake_latency_ms": 6.5,
      "first_byte_latency_ms": 0.4,
      "application_duration_ms": 2.0,
      "goodput_bps": 768000.0,
      "send_rate_datagrams_per_second": 4000.0,
      "datagram_latency_ms": {
        "p50": 0.2,
        "p95": 0.4,
        "p99": 0.4
      }
    }
    """
  end

  defp paced_datagram_quicprobe_json(overrides \\ []) do
    offered_rate_ratio = Keyword.get(overrides, :offered_rate_ratio, 1.0)
    offered_rate_valid = Keyword.get(overrides, :offered_rate_valid, true)

    """
    {
      "schema_version": "quicprobe-v1",
      "record_type": "client_run",
      "tool": "quicprobe",
      "reference_implementation": "quic-go",
      "reference_version": "v0.50.1",
      "started_at": "2026-05-21T10:15:13Z",
      "finished_at": "2026-05-21T10:15:15Z",
      "remote_addr": "127.0.0.1:4433",
      "alpn": "moqx-test",
      "workload": "datagram_pressure",
      "payload_size_bytes": 64,
      "datagram_size_bytes": 64,
      "datagram_count": 10,
      "datagram_mode": "paced",
      "target_datagrams_per_second": 5.0,
      "target_duration_seconds": 2,
      "offered_rate_ratio": #{offered_rate_ratio},
      "offered_rate_tolerance": 0.95,
      "offered_rate_valid": #{offered_rate_valid},
      "datagrams_offered": 10,
      "datagrams_accepted": 10,
      "datagrams_received": 9,
      "datagram_delivery_ratio": 0.9,
      "datagram_drop_count": 1,
      "bytes_sent": 640,
      "bytes_received": 576,
      "handshake_latency_ms": 6.5,
      "first_byte_latency_ms": 0.4,
      "application_duration_ms": 2000.0,
      "send_duration_ms": 2100.0,
      "target_send_duration_ms": 2000.0,
      "scheduled_send_span_ms": 1800.0,
      "send_pacing_late_count": 2,
      "send_pacing_lag_ms": {
        "p50": 0.2,
        "p95": 0.8,
        "p99": 0.8
      },
      "send_datagram_call_slow_count": 3,
      "send_datagram_call_slow_threshold_ms": 0.2,
      "send_datagram_call_total_ms": 4.4,
      "send_datagram_call_ms": {
        "p50": 0.3,
        "p95": 1.4,
        "p99": 1.4,
        "p999": 1.9,
        "max": 2.0
      },
      "offered_load_bps": 2560.0,
      "goodput_bps": 2304.0,
      "send_rate_datagrams_per_second": 5.0,
      "datagram_latency_ms": {
        "p50": 0.2,
        "p95": 0.4,
        "p99": 0.4
      }
    }
    """
  end

  defp mixed_quicprobe_json do
    """
    {
      "schema_version": "quicprobe-v1",
      "record_type": "client_run",
      "tool": "quicprobe",
      "reference_implementation": "quic-go",
      "reference_version": "v0.50.1",
      "started_at": "2026-05-21T10:15:13Z",
      "finished_at": "2026-05-21T10:15:14Z",
      "remote_addr": "127.0.0.1:4433",
      "alpn": "moqx-test",
      "workload": "mixed_moqt_shaped",
      "stream_direction": "mixed",
      "stream_count": 2,
      "payload_size_bytes": 512,
      "payload_count": 2,
      "control_payload_size_bytes": 32,
      "control_message_count": 3,
      "control_messages_per_second": 2.0,
      "control_trickle_bps": 512.0,
      "bytes_sent": 2144,
      "bytes_received": 96,
      "handshake_latency_ms": 6.5,
      "first_byte_latency_ms": 1.0,
      "application_duration_ms": 2.0,
      "goodput_bps": 8576000.0,
      "send_rate_packets_per_second": 3500.0,
      "stream_scheduling": "mixed_control_bidi_object_uni",
      "stream_latency_ms": {
        "p50": 1.0,
        "p95": 1.4,
        "p99": 1.4
      },
      "control_latency_ms": {
        "p50": 1.0,
        "p95": 3.0,
        "p99": 3.0
      }
    }
    """
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "moqx-reference-comparison-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defmodule PeerShutdownTransport do
    @behaviour MOQX.Transport

    @impl true
    def listen(_port, _opts), do: {:error, :unsupported}

    @impl true
    def accept(_listener, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def handshake(connection, _timeout), do: {:ok, connection}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:ok, :connection}

    @impl true
    def open_stream(_connection, _opts), do: {:ok, {:stream, make_ref()}}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(stream, _data, opts) do
      if Keyword.get(opts, :finish, false) do
        send(self(), {:moqx_transport, {:stream_event, stream, :peer_finished_sending, %{}}})
      end

      :ok
    end

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :peer_send_shutdown}

    @impl true
    def send_datagram(_connection, _data), do: {:error, :unsupported}

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
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}
  end

  defmodule DatagramSendErrorTransport do
    @behaviour MOQX.Transport

    @impl true
    def listen(_port, _opts), do: {:error, :unsupported}

    @impl true
    def accept(_listener, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def handshake(connection, _timeout), do: {:ok, connection}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:ok, :connection}

    @impl true
    def open_stream(_connection, _opts), do: {:error, :unsupported}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(_stream, _data, _opts), do: {:error, :unsupported}

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :unsupported}

    @impl true
    def send_datagram(_connection, _data), do: {:error, :invalid_parameter}

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
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}
  end

  defmodule DatagramEchoTransport do
    @behaviour MOQX.Transport

    @impl true
    def listen(_port, _opts), do: {:error, :unsupported}

    @impl true
    def accept(_listener, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def handshake(connection, _timeout), do: {:ok, connection}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:ok, :connection}

    @impl true
    def open_stream(_connection, _opts), do: {:error, :unsupported}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(_stream, _data, _opts), do: {:error, :unsupported}

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :unsupported}

    @impl true
    def send_datagram(connection, data) do
      send(self(), {:moqx_transport, {:datagram, connection, data, %{}}})
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
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}
  end

  defmodule DatagramSilentTransport do
    @behaviour MOQX.Transport

    @impl true
    def listen(_port, _opts), do: {:error, :unsupported}

    @impl true
    def accept(_listener, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def handshake(connection, _timeout), do: {:ok, connection}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:ok, :connection}

    @impl true
    def open_stream(_connection, _opts), do: {:error, :unsupported}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(_stream, _data, _opts), do: {:error, :unsupported}

    @impl true
    def recv_stream(_stream, _byte_count), do: {:error, :unsupported}

    @impl true
    def send_datagram(_connection, _data), do: :ok

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
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}
  end

  defmodule MixedEchoTransport do
    @behaviour MOQX.Transport

    @impl true
    def listen(_port, _opts), do: {:error, :unsupported}

    @impl true
    def accept(_listener, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def handshake(connection, _timeout), do: {:ok, connection}

    @impl true
    def connect(_host, _port, _opts, _timeout), do: {:ok, :connection}

    @impl true
    def open_stream(_connection, opts),
      do: {:ok, {:stream, make_ref(), Keyword.fetch!(opts, :direction)}}

    @impl true
    def accept_stream(_connection, _opts, _timeout), do: {:error, :unsupported}

    @impl true
    def send_stream(stream, data, opts) do
      send(self(), {:moqx_transport, {:stream_event, stream, :send_complete, false}})

      case stream do
        {:stream, _ref, :bidirectional} ->
          send(self(), {:moqx_transport, {:stream_data, stream, data, %{}}})

          if Keyword.get(opts, :finish, false) do
            send(self(), {:moqx_transport, {:stream_event, stream, :closed, %{}}})
          end

        _stream ->
          :ok
      end

      :ok
    end

    @impl true
    def recv_stream(_stream, byte_count), do: {:ok, :binary.copy(<<0>>, byte_count)}

    @impl true
    def send_datagram(_connection, _data), do: {:error, :unsupported}

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
    def capabilities(_connection), do: %MOQX.Transport.Capabilities{}
  end
end
