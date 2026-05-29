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
    after
      TransportTelemetryCollector.close(collector)
    end
  end
end
