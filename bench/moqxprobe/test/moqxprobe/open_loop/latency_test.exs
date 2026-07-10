defmodule MOQXProbe.OpenLoop.LatencyTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.OpenLoop.Latency

  test "records corrected (from scheduled) and uncorrected (from sent) on completion" do
    lat =
      Latency.new()
      |> Latency.on_send(:s1, 0, 1)
      |> Latency.on_complete(:s1, 11)

    summary = Latency.summary(lat)
    assert summary.corrected.count == 1
    assert summary.uncorrected.count == 1
    # corrected = 11 - 0 = 11 ms; uncorrected = 11 - 1 = 10 ms (exact min/max).
    assert summary.corrected.min == 11.0
    assert summary.uncorrected.min == 10.0
  end

  test "correlates completions per stream in FIFO order" do
    lat =
      Latency.new()
      |> Latency.on_send(:s1, 0, 0)
      |> Latency.on_send(:s1, 1, 1)
      |> Latency.on_complete(:s1, 10)
      |> Latency.on_complete(:s1, 21)

    summary = Latency.summary(lat)
    # first completion matches (0,0) => corrected 10; second matches (1,1) => 20.
    assert summary.corrected.count == 2
    assert summary.uncorrected.count == 2
    assert summary.corrected.min == 10.0
    assert summary.corrected.max == 20.0
  end

  test "finalize back-fills never-completed intents into corrected only" do
    lat =
      Latency.new()
      |> Latency.on_send(:s1, 0, 0)
      |> Latency.on_send(:s1, 5, 5)
      |> Latency.on_complete(:s1, 10)

    lat = Latency.finalize(lat, 100)
    summary = Latency.summary(lat)

    # corrected has the completed sample (10) plus the back-filled one (100-5=95).
    assert summary.corrected.count == 2
    assert summary.corrected.max == 95.0
    # uncorrected only ever saw the one completed send.
    assert summary.uncorrected.count == 1

    lat = Latency.on_complete(lat, :s1, 200)
    assert Latency.summary(lat).corrected.count == 2
  end

  test "a completion with no pending intent is ignored" do
    lat = Latency.on_complete(Latency.new(), :unknown, 42)
    assert Latency.summary(lat).corrected.count == 0
  end

  test "corrected tail dominates uncorrected under stalls (back-filled omissions)" do
    # one fast completed send, plus many admitted-but-never-completed intents.
    lat = Latency.on_send(Latency.new(), :s1, 0, 0) |> Latency.on_complete(:s1, 2)

    lat =
      Enum.reduce(1..50, lat, fn i, lat -> Latency.on_send(lat, :s1, i, i) end)
      |> Latency.finalize(1_000)

    summary = Latency.summary(lat)
    assert summary.corrected.count == 51
    assert summary.uncorrected.count == 1
    # the corrected p99 reflects the stalled/omitted intents; uncorrected does not.
    assert summary.corrected.percentiles[0.99] > summary.uncorrected.percentiles[0.99]
  end
end
