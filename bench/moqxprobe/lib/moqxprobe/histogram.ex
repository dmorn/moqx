defmodule MOQXProbe.Histogram do
  @moduledoc """
  A bounded log-linear latency histogram (HdrHistogram-style), used by the
  open-loop paced sender to summarize send-completion latency without storing
  every sample (issue 56).

  Values are non-negative numbers (milliseconds). Resolution is linear at
  1-unit buckets below 16, then log-linear above it: each power-of-two octave is
  divided into 16 linear sub-buckets, giving a constant ~1/16 relative error at
  higher magnitudes. Bucket count grows only logarithmically with the largest
  value, so memory is bounded and the counts map holds only populated buckets.

  Pure: no IO, no `Application` env.
  """

  @sub_buckets 16

  defstruct counts: %{}, total: 0, min: nil, max: nil, sum: 0.0

  @type t :: %__MODULE__{
          counts: %{optional(non_neg_integer()) => pos_integer()},
          total: non_neg_integer(),
          min: number() | nil,
          max: number() | nil,
          sum: float()
        }

  @default_quantiles [0.5, 0.9, 0.99, 0.999]

  @doc "Builds an empty histogram."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Records one non-negative value (negatives are clamped to 0)."
  @spec record(t(), number()) :: t()
  def record(%__MODULE__{} = h, value) when is_number(value) do
    v = max(value, 0) * 1.0
    index = index_for(v)

    %{
      h
      | counts: Map.update(h.counts, index, 1, &(&1 + 1)),
        total: h.total + 1,
        min: min_nil(h.min, v),
        max: max_nil(h.max, v),
        sum: h.sum + v
    }
  end

  @doc """
  The value at quantile `q` in `[0, 1]`, or `nil` for an empty histogram. Returns
  the representative (midpoint) value of the bucket holding the ranked sample.
  """
  @spec percentile(t(), float()) :: float() | nil
  def percentile(%__MODULE__{total: 0}, _q), do: nil

  def percentile(%__MODULE__{} = h, q) when is_number(q) do
    q = q |> max(0.0) |> min(1.0)
    rank = max(ceil(q * h.total), 1)

    h.counts
    |> Enum.sort_by(fn {index, _count} -> index end)
    |> rank_index(rank)
    |> value_for()
  end

  @doc """
  A summary map: count, min, max, mean, and a percentiles map (default
  p50/p90/p99/p99.9). All latency values are milliseconds.
  """
  @spec summary(t(), [float()]) :: map()
  def summary(%__MODULE__{} = h, quantiles \\ @default_quantiles) do
    %{
      count: h.total,
      min: h.min,
      max: h.max,
      mean: if(h.total > 0, do: h.sum / h.total, else: nil),
      percentiles: Map.new(quantiles, fn q -> {q, percentile(h, q)} end)
    }
  end

  # --- bucket math -----------------------------------------------------------

  defp index_for(v) when v < @sub_buckets, do: trunc(v)

  defp index_for(v) do
    octave = trunc(:math.log2(v / @sub_buckets))
    base = @sub_buckets * :math.pow(2, octave)
    step = base / @sub_buckets
    sub_index = trunc((v - base) / step)
    @sub_buckets + octave * @sub_buckets + sub_index
  end

  defp value_for(index) when index < @sub_buckets, do: index + 0.5

  defp value_for(index) do
    rel = index - @sub_buckets
    octave = div(rel, @sub_buckets)
    sub_index = rem(rel, @sub_buckets)
    base = @sub_buckets * :math.pow(2, octave)
    step = base / @sub_buckets
    base + (sub_index + 0.5) * step
  end

  defp rank_index(sorted_counts, rank) do
    Enum.reduce_while(sorted_counts, 0, fn {index, count}, cumulative ->
      cumulative = cumulative + count
      if cumulative >= rank, do: {:halt, index}, else: {:cont, cumulative}
    end)
  end

  defp min_nil(nil, v), do: v
  defp min_nil(a, v), do: min(a, v)

  defp max_nil(nil, v), do: v
  defp max_nil(a, v), do: max(a, v)
end
