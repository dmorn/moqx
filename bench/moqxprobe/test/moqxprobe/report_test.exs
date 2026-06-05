defmodule MOQXProbe.ReportTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Report

  test "renders a readable step summary" do
    report = Report.render([record()])

    assert report =~ "Transport Benchmark Report"
    assert report =~ "Records: 1"
    assert report =~ "draft_14"
    assert report =~ "stream_pressure"
    assert report =~ "1.00 Mbps"
    assert report =~ "loopback calibration only"
  end

  test "renders numeric datagram delivery percentages" do
    record =
      record()
      |> put_in(["workload", "family"], "datagram_pressure")
      |> put_in(["workload", "step"], "datagram_pressure")
      |> put_in(["workload", "stream_count"], nil)
      |> put_in(["workload", "payload_size_bytes"], 64)
      |> put_in(["workload", "datagram_size_bytes"], 64)
      |> put_in(["metrics", "goodput_bps"], 2_000_000.0)
      |> put_in(["metrics", "send_rate_packets_per_second"], 1_000.0)
      |> put_in(["metrics", "send_rate_datagrams_per_second"], 1_000.0)
      |> put_in(["metrics", "delivered_datagrams_per_second"], 1_000.0)
      |> put_in(["metrics", "datagram_delivery_ratio"], 1)
      |> put_in(["metrics", "datagram_drop_count"], 0)

    report = Report.render([record])

    assert report =~ "datagram_pressure"
    assert report =~ "100.00%"
  end

  test "renders integer-like float datagram delivery percentages" do
    record =
      record()
      |> put_in(["workload", "family"], "datagram_pressure")
      |> put_in(["workload", "step"], "datagram_pressure")
      |> put_in(["metrics", "datagram_delivery_ratio"], 1.0)

    report = Report.render([record])

    assert report =~ "100.00%"
  end

  test "renders profile workload when a measurement record has no step" do
    record =
      record()
      |> put_in(["profile", "name"], "reference_quic")
      |> put_in(["profile", "settings"], %{"workload" => "datagram_pressure"})
      |> put_in(["workload", "family"], "measurement")
      |> update_in(["workload"], &Map.delete(&1, "step"))

    report = Report.render([record])

    assert report =~ "datagram_pressure"
  end

  test "renders timed out steps in the limits section" do
    record =
      record()
      |> put_in(["limits", "first_break_symptom"], "step_timeout")
      |> put_in(["limits", "stopped_by"], "iperf3_step_timeout")
      |> put_in(["errors", "close_reason"], "timeout")
      |> put_in(["errors", "error_code"], 124)
      |> put_in(["errors", "message"], "iperf3 timed out after 2s")

    report = Report.render([record])

    assert report =~ "Limit: stream_pressure first=step_timeout stopped_by=iperf3_step_timeout"
    assert report =~ "iperf3 timed out after 2s"
  end

  test "renders diagnostics summary when present" do
    record =
      record()
      |> Map.put("diagnostics", %{
        "summary" => %{
          "bytes_sent" => 2048,
          "bytes_received" => 2048,
          "send_completions" => 4,
          "send_completions_pending" => 0,
          "events_drained" => 8
        },
        "process" => %{
          "message_queue_len" => 0,
          "message_queue_len_peak" => 12
        }
      })

    report = Report.render([record])

    assert report =~ "Diagnostics"

    assert report =~
             "Diag: stream_pressure sent=2048 recv=2048 send_done=4 pending=0 events=8 mailbox=0/12"
  end

  defp record do
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
end
