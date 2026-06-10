defmodule MOQXProbe.TransportTelemetryCollectorTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.TransportTelemetryCollector

  test "aggregates transport telemetry for one owner process" do
    assert {:ok, collector} = TransportTelemetryCollector.start(sample_process?: true)

    try do
      :telemetry.execute(
        [:moqx, :transport, :stream, :send, :stop],
        %{duration_us: 10, byte_size: 1200},
        %{result: :ok, stream_direction: :bidirectional, local_role: :client}
      )

      :telemetry.execute(
        [:moqx, :transport, :stream, :recv, :stop],
        %{duration_us: 8, requested_byte_count: 1200, byte_size: 1200},
        %{result: :ok, stream_direction: :bidirectional, local_role: :server}
      )

      :telemetry.execute(
        [:moqx, :transport, :datagram, :send, :stop],
        %{duration_us: 3, byte_size: 512},
        %{result: :ok, local_role: :client}
      )

      :telemetry.execute(
        [:moqx, :transport, :event, :receive, :stop],
        %{duration_us: 20, timeout_ms: 5, byte_size: 1200},
        %{
          result: :ok,
          event_kind: :stream_data,
          event_name: nil,
          local_role: :client
        }
      )

      :telemetry.execute(
        [:moqx, :transport, :event, :receive, :stop],
        %{duration_us: 5, timeout_ms: 0},
        %{
          result: :ok,
          event_kind: :stream_event,
          event_name: :send_completed,
          local_role: :client
        }
      )

      :telemetry.execute(
        [:moqx, :transport, :event, :receive, :stop],
        %{duration_us: 7, timeout_ms: 0, byte_size: 512},
        %{
          result: :ok,
          event_kind: :datagram,
          event_name: nil,
          local_role: :client
        }
      )

      :telemetry.execute(
        [:moqx, :transport, :event, :receive, :stop],
        %{duration_us: 1, timeout_ms: 0},
        %{result: :timeout, event_kind: :timeout, event_name: nil}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :datagram_sender, :run, :start],
        %{count: 4, rate_per_second: 2_000, max_burst: 2, max_queue_depth: 2},
        %{sender: :datagram}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :datagram_sender, :demand, :ask],
        %{demand_count: 2, outstanding_demand: 2, queue_depth: 0, max_queue_depth: 2},
        %{sender: :datagram, sink: :datagram_sink}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :datagram_sender, :backlog, :change],
        %{enqueued_count: 2, outstanding_demand: 0, queue_depth: 2, max_queue_depth: 2},
        %{sender: :datagram, sink: :datagram_sink}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :datagram_sender, :tick, :stop],
        %{
          lag_ms: 1,
          due_count: 4,
          target_emitted: 4,
          send_count: 2,
          accepted_count: 1,
          error_count: 1,
          capped_tick_count: 1,
          tool_limited_tick_count: 0,
          burst_duration_us: 9,
          queue_depth: 0,
          outstanding_demand: 0
        },
        %{sender: :datagram, sink: :datagram_sink, result: :error, stop_reason: :complete}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :datagram_sender, :send, :error],
        %{error_count: 1},
        %{sender: :datagram, sink: :datagram_sink, error_reasons: [":blocked"]}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :datagram_sender, :run, :stop],
        %{accepted_count: 1, error_count: 1, queue_depth: 0, max_queue_depth: 2},
        %{sender: :datagram, result: :ok, stop_reason: :complete}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :stream_sender, :run, :start],
        %{count: 4, max_burst: 2, max_queue_depth: 2},
        %{sender: :stream}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :stream_sender, :demand, :ask],
        %{demand_count: 2, outstanding_demand: 2, queue_depth: 0, max_queue_depth: 2},
        %{sender: :stream, sink: :stream_sink}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :stream_sender, :backlog, :change],
        %{enqueued_count: 2, outstanding_demand: 0, queue_depth: 2, max_queue_depth: 2},
        %{sender: :stream, sink: :stream_sink}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :stream_sender, :tick, :stop],
        %{
          lag_ms: 1,
          due_count: 4,
          target_emitted: 4,
          send_count: 2,
          accepted_count: 1,
          error_count: 1,
          capped_tick_count: 1,
          tool_limited_tick_count: 0,
          stream_window_limited_tick_count: 1,
          burst_duration_us: 11,
          queue_depth: 0,
          outstanding_demand: 0,
          in_flight: 1
        },
        %{sender: :stream, sink: :stream_sink, result: :error, stop_reason: :complete}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :stream_sender, :send, :error],
        %{error_count: 1},
        %{sender: :stream, sink: :stream_sink, error_reasons: [":blocked"]}
      )

      :telemetry.execute(
        [:moqx, :transport_bench, :stream_sender, :run, :stop],
        %{
          accepted_count: 1,
          completed_count: 1,
          error_count: 1,
          queue_depth: 0,
          max_queue_depth: 2
        },
        %{sender: :stream, result: :ok, stop_reason: :complete}
      )

      snapshot = TransportTelemetryCollector.snapshot(collector)

      assert snapshot.stream_send_accepted == 1
      assert snapshot.stream_send_errors == 0
      assert snapshot.stream_send_bytes_accepted == 1200
      assert snapshot.send_stream_call_durations_us == [10]
      assert snapshot.stream_recv_ok == 1
      assert snapshot.stream_recv_errors == 0
      assert snapshot.stream_recv_bytes == 1200
      assert snapshot.recv_stream_call_durations_us == [8]
      assert snapshot.datagram_send_accepted == 1
      assert snapshot.datagram_send_errors == 0
      assert snapshot.datagram_send_bytes_accepted == 512
      assert snapshot.send_datagram_call_durations_us == [3]

      runtime = snapshot.runtime_diagnostics
      assert runtime.events_drained == 3
      assert runtime.stream_data_events == 1
      assert runtime.stream_data_bytes_received == 1200
      assert runtime.datagram_events == 1
      assert runtime.datagram_bytes_received == 512
      assert runtime.send_completed_events == 1
      assert runtime.timeouts == 1
      assert runtime.receive_event_call_durations_us == [20, 5, 7, 1]
      assert runtime.receive_event_blocking_call_durations_us == [20]
      assert runtime.receive_event_drain_call_durations_us == [5, 7, 1]
      assert runtime.process["message_queue_len_samples"] >= 1

      assert runtime.beam["schedulers_online"] >= 1
      assert runtime.beam["dirty_cpu_schedulers"] >= 1
      assert runtime.beam["dirty_io_schedulers"] >= 1
      assert runtime.beam["scheduler_wall_time"]["entry_count"] >= 1
      assert is_number(runtime.beam["scheduler_wall_time"]["utilization_percent"])
      assert is_integer(runtime.beam["run_queue"]["finish"])
      assert is_integer(runtime.beam["owner_process"]["reductions_delta"])

      assert runtime.datagram_sender == %{
               runs_started: 1,
               runs_stopped: 1,
               runs_failed: 0,
               demand_asked: 2,
               payloads_enqueued: 2,
               ticks: 1,
               due: 4,
               sent: 2,
               accepted: 1,
               errors: 1,
               send_error_events: 1,
               capped_ticks: 1,
               tool_limited_ticks: 0,
               burst_durations_us: [9]
             }

      assert runtime.stream_sender == %{
               runs_started: 1,
               runs_stopped: 1,
               runs_failed: 0,
               demand_asked: 2,
               payloads_enqueued: 2,
               ticks: 1,
               due: 4,
               sent: 2,
               accepted: 1,
               completed: 1,
               errors: 1,
               send_error_events: 1,
               capped_ticks: 1,
               tool_limited_ticks: 0,
               stream_window_limited_ticks: 1,
               burst_durations_us: [11]
             }
    after
      TransportTelemetryCollector.close(collector)
    end
  end
end
