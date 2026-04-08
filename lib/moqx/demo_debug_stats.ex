defmodule MOQX.DemoDebugStats do
  @moduledoc false

  alias MOQX.Debug

  defstruct [
    :started_at_ms,
    :bytes,
    :objects,
    :groups,
    :latency_count,
    :latency_sum_ms,
    :latency_min_ms,
    :latency_max_ms
  ]

  @type t :: %__MODULE__{
          started_at_ms: integer(),
          bytes: non_neg_integer(),
          objects: non_neg_integer(),
          groups: MapSet.t(non_neg_integer()),
          latency_count: non_neg_integer(),
          latency_sum_ms: non_neg_integer(),
          latency_min_ms: non_neg_integer() | nil,
          latency_max_ms: non_neg_integer() | nil
        }

  @spec new(integer()) :: t()
  def new(started_at_ms \\ System.system_time(:millisecond)) when is_integer(started_at_ms) do
    %__MODULE__{
      started_at_ms: started_at_ms,
      bytes: 0,
      objects: 0,
      groups: MapSet.new(),
      latency_count: 0,
      latency_sum_ms: 0,
      latency_min_ms: nil,
      latency_max_ms: nil
    }
  end

  @spec add_frame(t(), non_neg_integer(), binary(), integer()) :: t()
  def add_frame(
        %__MODULE__{} = stats,
        group_id,
        payload,
        now_ms \\ System.system_time(:millisecond)
      )
      when is_integer(group_id) and group_id >= 0 and is_binary(payload) and is_integer(now_ms) do
    stats =
      %{
        stats
        | bytes: stats.bytes + byte_size(payload),
          objects: stats.objects + 1,
          groups: MapSet.put(stats.groups, group_id)
      }

    case Debug.publisher_age_ms(payload, now_ms) do
      {:ok, latency_ms} ->
        %{
          stats
          | latency_count: stats.latency_count + 1,
            latency_sum_ms: stats.latency_sum_ms + latency_ms,
            latency_min_ms: min_latency(stats.latency_min_ms, latency_ms),
            latency_max_ms: max_latency(stats.latency_max_ms, latency_ms)
        }

      {:error, _reason} ->
        stats
    end
  end

  @spec snapshot(t(), integer()) :: map()
  def snapshot(%__MODULE__{} = stats, ended_at_ms) when is_integer(ended_at_ms) do
    duration_ms = max(ended_at_ms - stats.started_at_ms, 1)
    duration_s = duration_ms / 1_000

    %{
      duration_ms: duration_ms,
      bytes_per_sec: stats.bytes / duration_s,
      bitrate_kbps: stats.bytes * 8 / duration_s / 1_000,
      groups_per_sec: MapSet.size(stats.groups) / duration_s,
      objects_per_sec: stats.objects / duration_s,
      latency: latency_snapshot(stats)
    }
  end

  @spec format_snapshot(map()) :: String.t()
  def format_snapshot(snapshot) do
    latency_text =
      case snapshot.latency do
        nil ->
          "n/a"

        latency ->
          "avg=#{latency.avg_ms}ms min=#{latency.min_ms}ms max=#{latency.max_ms}ms n=#{latency.samples}"
      end

    "bw=#{format_rate(snapshot.bytes_per_sec)} B/s (#{format_rate(snapshot.bitrate_kbps)} kbps) " <>
      "groups/s=#{format_rate(snapshot.groups_per_sec)} objects/s=#{format_rate(snapshot.objects_per_sec)} " <>
      "latency=#{latency_text}"
  end

  defp latency_snapshot(%__MODULE__{latency_count: 0}), do: nil

  defp latency_snapshot(%__MODULE__{} = stats) do
    %{
      samples: stats.latency_count,
      avg_ms: div(stats.latency_sum_ms, stats.latency_count),
      min_ms: stats.latency_min_ms,
      max_ms: stats.latency_max_ms
    }
  end

  defp format_rate(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp min_latency(nil, value), do: value
  defp min_latency(current, value), do: min(current, value)

  defp max_latency(nil, value), do: value
  defp max_latency(current, value), do: max(current, value)
end
