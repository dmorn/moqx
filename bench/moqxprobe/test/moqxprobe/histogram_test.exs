defmodule MOQXProbe.HistogramTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Histogram

  defp record_all(h, values), do: Enum.reduce(values, h, &Histogram.record(&2, &1))

  test "tracks count, exact min/max, and mean" do
    h = record_all(Histogram.new(), [10, 20, 30])
    assert h.total == 3
    assert h.min == 10.0
    assert h.max == 30.0
    assert Histogram.summary(h).mean == 20.0
  end

  test "empty histogram has nil percentiles" do
    h = Histogram.new()
    assert Histogram.percentile(h, 0.5) == nil
    assert Histogram.summary(h).count == 0
  end

  test "percentiles of a uniform 1..1000 distribution are accurate within tolerance" do
    h = record_all(Histogram.new(), Enum.to_list(1..1000))

    p50 = Histogram.percentile(h, 0.5)
    p90 = Histogram.percentile(h, 0.9)
    p99 = Histogram.percentile(h, 0.99)

    # log-linear buckets give a bounded relative error; assert within ~10%.
    assert_in_delta p50, 500, 50
    assert_in_delta p90, 900, 90
    assert_in_delta p99, 990, 99

    # monotonic across quantiles.
    assert p50 <= p90
    assert p90 <= p99
    assert h.max == 1000.0
  end

  test "sub-octave resolution is fine at low magnitudes" do
    # values below the fixed sub-bucket count fall in 1-unit linear buckets.
    h = record_all(Histogram.new(), [1, 2, 3, 4, 5])
    assert_in_delta Histogram.percentile(h, 0.5), 3, 1
  end

  test "negative values are clamped to zero" do
    h = Histogram.record(Histogram.new(), -5)
    assert h.total == 1
    assert h.min == 0.0
  end
end
