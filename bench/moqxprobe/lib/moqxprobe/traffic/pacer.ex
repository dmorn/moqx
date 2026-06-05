defmodule MOQXProbe.Traffic.Pacer do
  @moduledoc false

  defmodule Tick do
    @moduledoc false

    defstruct [
      :scheduled_at_ms,
      :now_ms,
      :lag_ms,
      :elapsed_ms,
      :target_emitted,
      :due_count,
      :send_count,
      :stop_reason,
      capped?: false,
      tool_limited?: false
    ]
  end

  defstruct [
    :count,
    :rate_per_second,
    :tick_ms,
    :max_burst,
    :max_lag_ms,
    :started_at_ms,
    :next_deadline_ms,
    emitted_count: 0,
    tick_count: 0,
    capped_tick_count: 0,
    empty_tick_count: 0,
    tool_limited_tick_count: 0
  ]

  def new!(opts) when is_list(opts) do
    count = positive_integer!(opts, :count)
    rate_per_second = positive_integer!(opts, :rate_per_second)
    tick_ms = positive_integer!(opts, :tick_ms)
    max_burst = positive_integer!(opts, :max_burst)
    started_at_ms = integer!(opts, :started_at_ms)
    max_lag_ms = optional_non_negative_integer!(opts, :max_lag_ms)

    %__MODULE__{
      count: count,
      rate_per_second: rate_per_second,
      tick_ms: tick_ms,
      max_burst: max_burst,
      max_lag_ms: max_lag_ms,
      started_at_ms: started_at_ms,
      next_deadline_ms: started_at_ms + tick_ms
    }
  end

  def next_deadline_ms(%__MODULE__{next_deadline_ms: next_deadline_ms}),
    do: next_deadline_ms

  def complete?(%__MODULE__{count: count, emitted_count: emitted_count}),
    do: emitted_count >= count

  def tick(%__MODULE__{} = pacer, now_ms) when is_integer(now_ms) do
    scheduled_at_ms = pacer.next_deadline_ms
    lag_ms = now_ms - scheduled_at_ms
    elapsed_ms = max(now_ms - pacer.started_at_ms, 0)
    target_emitted = target_emitted(pacer, elapsed_ms)
    due_count = max(target_emitted - pacer.emitted_count, 0)
    remaining = max(pacer.count - pacer.emitted_count, 0)
    tool_limited? = tool_limited?(pacer, lag_ms)
    send_count = send_count(due_count, remaining, pacer.max_burst, tool_limited?)
    capped? = !tool_limited? and due_count > send_count and remaining > send_count
    emitted_count = pacer.emitted_count + send_count
    stop_reason = stop_reason(tool_limited?, emitted_count, pacer.count)

    tick = %Tick{
      scheduled_at_ms: scheduled_at_ms,
      now_ms: now_ms,
      lag_ms: lag_ms,
      elapsed_ms: elapsed_ms,
      target_emitted: target_emitted,
      due_count: due_count,
      send_count: send_count,
      capped?: capped?,
      tool_limited?: tool_limited?,
      stop_reason: stop_reason
    }

    pacer =
      pacer
      |> Map.put(:emitted_count, emitted_count)
      |> Map.put(:next_deadline_ms, scheduled_at_ms + pacer.tick_ms)
      |> Map.update!(:tick_count, &(&1 + 1))
      |> maybe_increment(:empty_tick_count, send_count == 0)
      |> maybe_increment(:capped_tick_count, capped?)
      |> maybe_increment(:tool_limited_tick_count, tool_limited?)

    {tick, pacer}
  end

  defp target_emitted(pacer, elapsed_ms) do
    min(pacer.count, div(elapsed_ms * pacer.rate_per_second, 1_000))
  end

  defp send_count(_due_count, _remaining, _max_burst, true), do: 0

  defp send_count(due_count, remaining, max_burst, false) do
    due_count
    |> min(remaining)
    |> min(max_burst)
  end

  defp stop_reason(true, _emitted_count, _count), do: :tool_limited

  defp stop_reason(_tool_limited?, emitted_count, count) when emitted_count >= count,
    do: :complete

  defp stop_reason(_tool_limited?, _emitted_count, _count), do: nil

  defp tool_limited?(%__MODULE__{max_lag_ms: nil}, _lag_ms), do: false
  defp tool_limited?(%__MODULE__{max_lag_ms: max_lag_ms}, lag_ms), do: lag_ms > max_lag_ms

  defp maybe_increment(pacer, key, true), do: Map.update!(pacer, key, &(&1 + 1))
  defp maybe_increment(pacer, _key, false), do: pacer

  defp positive_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        value

      _missing_or_invalid ->
        raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) ->
        value

      _missing_or_invalid ->
        raise ArgumentError, "#{key} must be an integer"
    end
  end

  defp optional_non_negative_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        value

      {:ok, _value} ->
        raise ArgumentError, "#{key} must be a non-negative integer"

      :error ->
        nil
    end
  end
end
