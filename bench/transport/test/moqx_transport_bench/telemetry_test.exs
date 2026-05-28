defmodule MOQX.TransportBench.TelemetryTest do
  use ExUnit.Case, async: true

  alias MOQX.TransportBench.Telemetry, as: BenchTelemetry

  test "declares transport metrics for telemetry-backed benchmark collection" do
    metrics = BenchTelemetry.metrics()

    assert_metric(metrics, Telemetry.Metrics.Counter, [:moqx, :transport, :stream, :send, :stop])
    assert_metric(metrics, Telemetry.Metrics.Summary, [:moqx, :transport, :stream, :send, :stop])
    assert_metric(metrics, Telemetry.Metrics.Sum, [:moqx, :transport, :stream, :send, :stop])

    assert_metric(metrics, Telemetry.Metrics.Counter, [:moqx, :transport, :stream, :recv, :stop])
    assert_metric(metrics, Telemetry.Metrics.Summary, [:moqx, :transport, :stream, :recv, :stop])
    assert_metric(metrics, Telemetry.Metrics.Sum, [:moqx, :transport, :stream, :recv, :stop])

    assert_metric(metrics, Telemetry.Metrics.Counter, [:moqx, :transport, :event, :receive, :stop])

    assert_metric(metrics, Telemetry.Metrics.Summary, [:moqx, :transport, :event, :receive, :stop])

    assert_metric(metrics, Telemetry.Metrics.Sum, [:moqx, :transport, :event, :receive, :stop])

    assert_metric(metrics, Telemetry.Metrics.Counter, [
      :moqx,
      :transport,
      :datagram,
      :send,
      :stop
    ])
  end

  defp assert_metric(metrics, module, event_name) do
    assert Enum.any?(metrics, fn metric ->
             metric.__struct__ == module and metric.event_name == event_name
           end)
  end
end
