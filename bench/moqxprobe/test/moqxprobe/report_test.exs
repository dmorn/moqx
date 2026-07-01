defmodule MOQXProbe.ReportTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Report

  describe "validate_metric_name!/1" do
    test "accepts explicit, qualified names" do
      assert :ok = Report.validate_metric_name!("receiver_payload_goodput_active_bps")
      assert :ok = Report.validate_metric_name!("receiver_payload_goodput_interval_p95_bps")
      assert :ok = Report.validate_metric_name!("client_payload_goodput_sender_active_bps")
      assert :ok = Report.validate_metric_name!("datagrams_received_per_second")
    end

    test "rejects naked bandwidth" do
      assert_raise ArgumentError, ~r/no naked bandwidth/, fn ->
        Report.validate_metric_name!("receiver_bandwidth_bps")
      end
    end

    test "rejects a goodput name without a denominator suffix" do
      assert_raise ArgumentError, ~r/must name its denominator/, fn ->
        Report.validate_metric_name!("receiver_payload_goodput")
      end
    end

    test "rejects stream pkts/s names" do
      assert_raise ArgumentError, ~r/pkts/, fn ->
        Report.validate_metric_name!("stream_pkts_per_second")
      end

      assert_raise ArgumentError, fn ->
        Report.validate_metric_name!("packets_per_second")
      end
    end
  end

  describe "build/1 receiver goodput (closed-loop)" do
    setup do
      %{report: Report.build(closed_loop_inputs())}
    end

    test "derives stream goodput over the receiver-active window", %{report: report} do
      metric = metric(report, "receiver_payload_goodput_active_bps")
      # 3_776_000 bytes over 1000 ms => 3_776_000 * 8 bits / 1s
      assert metric.value.median == 3_776_000 * 8
      assert metric.window == "receiver_active"
      assert metric.source_layer == "receiver"
      assert metric.tier == "remote_quic_no_wire"
    end

    test "derives pooled interval p95 from the bins", %{report: report} do
      metric = metric(report, "receiver_payload_goodput_interval_p95_bps")
      # each 100 ms bin carries 1_888_000 bytes => * 8 * (1000/100)
      assert metric.value == 1_888_000 * 8 * 10
      assert metric.window == "interval_bin"
    end

    test "warns that a closed-loop run tagged remote_quic is not a saturation claim", %{
      report: report
    } do
      assert Enum.any?(report.warnings, &String.contains?(&1, "not a remote saturation"))
    end
  end

  test "build/1 skips receiver goodput when no records are valid" do
    inputs = put_in(closed_loop_inputs().delivery, [invalid_record()])
    report = Report.build(inputs)

    assert metric(report, "receiver_payload_goodput_active_bps") == nil
    assert Enum.any?(report.warnings, &String.contains?(&1, "No valid receiver-evidence"))
  end

  describe "build/1 sender goodput (open-loop)" do
    setup do
      %{report: Report.build(open_loop_inputs())}
    end

    test "derives sender-active goodput from accepted events", %{report: report} do
      metric = metric(report, "client_payload_goodput_sender_active_bps")
      # 32_000 events * 1180 bytes * 8 bits over 4000 ms
      assert metric.value == 32_000 * 1180 * 8 * 1000 / 4000
      assert metric.window == "sender_active"
      assert metric.source_layer == "sender"
    end

    test "warns on the saturation verdict (completion deficit), not the raw CO flag", %{
      report: report
    } do
      assert Enum.any?(report.warnings, &String.contains?(&1, "Saturation detected"))
      assert Enum.any?(report.warnings, &String.contains?(&1, "completion deficit 7.4%"))
      assert Enum.any?(report.warnings, &String.contains?(&1, "issue 56"))
    end
  end

  test "build/1 treats a CO flag without saturation as a scheduling note, not saturation" do
    inputs =
      put_in(open_loop_inputs().paced["summary"], %{
        "accepted_payload_events_sender_active_total" => 32_000,
        "coordinated_omission" => true,
        "coordinated_omission_cause" => "sustained_tick_lag",
        "saturated" => false,
        "saturation_signal" => nil,
        "send_completion_deficit_ratio" => 0.0
      })

    report = Report.build(inputs)

    refute Enum.any?(report.warnings, &String.contains?(&1, "Saturation detected"))
    assert Enum.any?(report.warnings, &String.contains?(&1, "sender-scheduling signal"))
  end

  describe "build/1 iperf3 baseline" do
    test "computes receiver-active utilization only with an explicit target" do
      report = Report.build(closed_loop_inputs())
      median = metric(report, "receiver_payload_goodput_active_bps").value.median
      assert_in_delta report.baseline.receiver_active_utilization, median / 1_000_000_000, 1.0e-9
      assert report.baseline.protocol == "tcp"
    end

    test "skips the comparison when the target is not explicit" do
      inputs = put_in(closed_loop_inputs().manifest["target"], nil)
      report = Report.build(inputs)

      assert report.baseline == nil
      assert Enum.any?(report.warnings, &String.contains?(&1, "no explicit target"))
    end
  end

  test "build/1 summarizes host saturation" do
    report = Report.build(open_loop_inputs())
    assert report.saturation.sample_count == 2
    assert report.saturation.max_scheduler_utilization_fraction == 0.4
    assert report.saturation.max_total_run_queue_length == 7
    assert report.saturation.max_role_message_queue_len == 12
  end

  test "to_markdown/1 renders the sections without raising" do
    md = closed_loop_inputs() |> Report.build() |> Report.to_markdown()

    assert md =~ "# Benchmark run report"
    assert md =~ "receiver_payload_goodput_active_bps"
    assert md =~ "Path baseline (iperf3)"
    assert md =~ "Warnings"
  end

  # --- fixtures --------------------------------------------------------------

  defp closed_loop_inputs do
    %{
      manifest: %{
        "mode" => "closed_loop",
        "tier" => "remote_quic_no_wire",
        "target_type" => "remote_quic",
        "run_id" => "r-closed",
        "git_sha" => "abc123",
        "client_implementation" => "flow_partitions",
        "target" => %{"host" => "192.168.178.29", "quic_port" => 55_433},
        "workload" => %{"profile" => "draft14_object_stream"}
      },
      delivery: [valid_record()],
      paced: nil,
      host: nil,
      # RunMetadata.iperf3_summaries/1 returns atom-keyed maps with status: :ok.
      iperf3: [%{status: :ok, protocol: "tcp", bits_per_second: 1_000_000_000}]
    }
  end

  defp open_loop_inputs do
    %{
      manifest: %{
        "mode" => "open_loop",
        "tier" => "remote_quic_no_wire",
        "target_type" => "remote_quic",
        "run_id" => "r-open",
        "git_sha" => "abc123",
        "client_implementation" => "open_loop_paced",
        "target" => %{"host" => "192.168.178.29"},
        "workload" => %{"profile" => "draft14_object_stream"}
      },
      delivery: [],
      paced: %{
        "header" => %{"payload_size" => 1180, "duration_ms" => 4000},
        "summary" => %{
          "accepted_payload_events_sender_active_total" => 32_000,
          "coordinated_omission" => true,
          "coordinated_omission_cause" => "sustained_tick_lag",
          "saturated" => true,
          "saturation_signal" => "completion_deficit",
          "send_completion_deficit_ratio" => 0.074
        }
      },
      host: %{
        "samples" => [
          %{
            "scheduler_utilization_fraction" => 0.2,
            "total_run_queue_length" => 3,
            "roles" => [%{"role" => "paced_sender", "message_queue_len" => 5}]
          },
          %{
            "scheduler_utilization_fraction" => 0.4,
            "total_run_queue_length" => 7,
            "roles" => [%{"role" => "paced_sender", "message_queue_len" => 12}]
          }
        ]
      },
      iperf3: nil
    }
  end

  defp valid_record do
    %{
      "evidence" => %{
        "valid" => true,
        "observed" => %{"stream_bytes_received" => 3_776_000, "datagrams_received" => 0},
        "metadata" => %{
          "receiver_interval" => %{
            "bin_width_ms" => 100,
            "first_stream_byte_at_ms" => 1.0,
            "last_stream_byte_at_ms" => 1001.0,
            "bins" => [
              %{"stream_bytes" => 1_888_000},
              %{"stream_bytes" => 1_888_000}
            ]
          }
        }
      }
    }
  end

  defp invalid_record do
    %{"evidence" => %{"valid" => false, "observed" => %{}, "metadata" => %{}}}
  end

  defp metric(report, name), do: Enum.find(report.metrics, &(&1.name == name))
end
