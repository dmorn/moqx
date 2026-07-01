defmodule MOQXProbe.Histogram do
  @moduledoc """
  A bounded, mergeable log-linear latency histogram (HdrHistogram-style), used
  by the open-loop paced sender to summarize send-completion latency without
  storing every sample (issue 56).

  Values are non-negative numbers (milliseconds). Resolution is linear at
  1-unit buckets below `sub_buckets`, then log-linear above it: each power-of-two
  octave is divided into `sub_buckets` linear sub-buckets, giving a constant
  ~`1 / sub_buckets` relative error at higher magnitudes. Bucket count grows only
  logarithmically with the largest value, so memory is bounded and the counts map
  holds only populated buckets.

  Pure: no IO, no `Application` env. `merge/2` combines two histograms with the
  same `sub_buckets` (e.g. per-shard), so callers can accumulate independently.
  """

  @enforce_keys [:sub_buckets]
  defstruct sub_buckets: 16, counts: %{}, total: 0, min: nil, max: nil, sum: 0.0

  @type t :: %__MODULE__{
          sub_buckets: pos_integer(),
          counts: %{optional(non_neg_integer()) => pos_integer()},
          total: non_neg_integer(),
          min: number() | nil,
          max: number() | nil,
          sum: float()
        }

  @default_quantiles [0.5, 0.9, 0.99, 0.999]

  @doc """
  Builds an empty histogram. `:sub_buckets` (a positive integer, default `16`)
  sets the linear sub-divisions per octave — higher means finer resolution.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    sub = Keyword.get(opts, :sub_buckets, 16)

    unless is_integer(sub) and sub > 0 do
      raise ArgumentError, "sub_buckets must be a positive integer"
    end

    %__MODULE__{sub_buckets: sub}
  end

  @doc "Records one non-negative value (negatives are clamped to 0)."
  @spec record(t(), number()) :: t()
  def record(%__MODULE__{} = h, value) when is_number(value) do
    v = max(value, 0) * 1.0
    index = index_for(v, h.sub_buckets)

    %{
      h
      | counts: Map.update(h.counts, index, 1, &(&1 + 1)),
        total: h.total + 1,
        min: min_nil(h.min, v),
        max: max_nil(h.max, v),
        sum: h.sum + v
    }
  end

  @doc "Merges two histograms (same `sub_buckets`)."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{sub_buckets: sub} = a, %__MODULE__{sub_buckets: sub} = b) do
    %{
      a
      | counts: Map.merge(a.counts, b.counts, fn _index, x, y -> x + y end),
        total: a.total + b.total,
        min: min_nil(a.min, b.min),
        max: max_nil(a.max, b.max),
        sum: a.sum + b.sum
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
    |> value_for(h.sub_buckets)
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

  defp index_for(v, sub) when v < sub, do: trunc(v)

  defp index_for(v, sub) do
    octave = trunc(:math.log2(v / sub))
    base = sub * :math.pow(2, octave)
    step = base / sub
    sub_index = trunc((v - base) / step)
    sub + octave * sub + sub_index
  end

  defp value_for(index, sub) when index < sub, do: index + 0.5

  defp value_for(index, sub) do
    rel = index - sub
    octave = div(rel, sub)
    sub_index = rem(rel, sub)
    base = sub * :math.pow(2, octave)
    step = base / sub
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
