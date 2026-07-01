defmodule MOQXProbe.OpenLoop.Latency do
  @moduledoc """
  Pure send-completion latency accounting for the open-loop paced sender
  (issue 56).

  It correlates each offered intent with its later `send_completed` and records
  two latency distributions:

    * **corrected** — measured from the intent's *scheduled* time. A held-back
      intent's clock starts when it should have been sent, so coordinated
      omission is corrected by construction (Tene's record-with-expected-
      interval). `finalize/2` additionally back-fills intents that never
      completed (the issue-58 completion deficit) at `run_end - scheduled`, so
      the corrected tail reflects the stalls.
    * **uncorrected** — measured from the intent's *actual send* time, over only
      the sends that completed. This is the naive view that omits the stalls.

  Correlation is per-stream FIFO: QUIC completes a stream's sends in order, so
  each completion pops the oldest pending intent for that stream. All latencies
  are milliseconds. Pure: no IO, no `Application` env.
  """

  alias MOQXProbe.Histogram

  @enforce_keys [:corrected, :uncorrected]
  defstruct [:corrected, :uncorrected, pending: %{}]

  @type stream_key :: term()

  @type t :: %__MODULE__{
          corrected: Histogram.t(),
          uncorrected: Histogram.t(),
          pending: %{optional(stream_key()) => :queue.queue({number(), number()})}
        }

  @doc "Builds an empty latency collector. Options are passed to `Histogram.new/1`."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{corrected: Histogram.new(opts), uncorrected: Histogram.new(opts), pending: %{}}
  end

  @doc """
  Records an offered/sent intent by pushing `{scheduled_ms, sent_ms}` onto the
  stream's FIFO. `scheduled_ms` is when the schedule intended the send;
  `sent_ms` is when the transport actually admitted it.
  """
  @spec on_send(t(), stream_key(), number(), number()) :: t()
  def on_send(%__MODULE__{} = lat, stream_key, scheduled_ms, sent_ms) do
    queue = Map.get(lat.pending, stream_key, :queue.new())
    queue = :queue.in({scheduled_ms, sent_ms}, queue)
    %{lat | pending: Map.put(lat.pending, stream_key, queue)}
  end

  @doc """
  Records a completion for `stream_key` at `completed_ms`: pops the oldest
  pending intent for that stream and records the corrected and uncorrected
  latencies. A completion with no pending intent (spurious/extra) is ignored.
  """
  @spec on_complete(t(), stream_key(), number()) :: t()
  def on_complete(%__MODULE__{} = lat, stream_key, completed_ms) do
    case Map.get(lat.pending, stream_key) do
      nil ->
        lat

      queue ->
        case :queue.out(queue) do
          {{:value, {scheduled_ms, sent_ms}}, rest} ->
            %{
              lat
              | corrected: Histogram.record(lat.corrected, completed_ms - scheduled_ms),
                uncorrected: Histogram.record(lat.uncorrected, completed_ms - sent_ms),
                pending: put_or_drop(lat.pending, stream_key, rest)
            }

          {:empty, _rest} ->
            lat
        end
    end
  end

  @doc """
  Records a cancellation for `stream_key`: pops the oldest pending intent to keep
  the per-stream FIFO aligned, without recording a latency sample (a cancelled
  send neither completed nor stalled-until-end).
  """
  @spec on_cancel(t(), stream_key()) :: t()
  def on_cancel(%__MODULE__{} = lat, stream_key) do
    case Map.get(lat.pending, stream_key) do
      nil ->
        lat

      queue ->
        case :queue.out(queue) do
          {{:value, _intent}, rest} ->
            %{lat | pending: put_or_drop(lat.pending, stream_key, rest)}

          {:empty, _rest} ->
            lat
        end
    end
  end

  @doc """
  Back-fills every still-pending intent (admitted but never completed) into the
  corrected histogram at `end_ms - scheduled_ms`, then clears the pending queues.
  These are the coordinated-omission tail; the uncorrected histogram is left
  untouched (it deliberately omits them).
  """
  @spec finalize(t(), number()) :: t()
  def finalize(%__MODULE__{} = lat, end_ms) do
    corrected =
      Enum.reduce(lat.pending, lat.corrected, fn {_stream, queue}, hist ->
        Enum.reduce(:queue.to_list(queue), hist, fn {scheduled_ms, _sent_ms}, hist ->
          Histogram.record(hist, end_ms - scheduled_ms)
        end)
      end)

    %{lat | corrected: corrected, pending: %{}}
  end

  @doc "Number of intents still awaiting completion."
  @spec pending_count(t()) :: non_neg_integer()
  def pending_count(%__MODULE__{pending: pending}) do
    Enum.reduce(pending, 0, fn {_stream, queue}, acc -> acc + :queue.len(queue) end)
  end

  @doc "Corrected and uncorrected latency summaries (ms)."
  @spec summary(t(), [float()]) :: %{corrected: map(), uncorrected: map()}
  def summary(%__MODULE__{} = lat, quantiles \\ [0.5, 0.9, 0.99, 0.999]) do
    %{
      corrected: Histogram.summary(lat.corrected, quantiles),
      uncorrected: Histogram.summary(lat.uncorrected, quantiles)
    }
  end

  defp put_or_drop(pending, stream_key, queue) do
    if :queue.is_empty(queue) do
      Map.delete(pending, stream_key)
    else
      Map.put(pending, stream_key, queue)
    end
  end
end
