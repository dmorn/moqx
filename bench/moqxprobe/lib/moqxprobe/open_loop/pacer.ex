defmodule MOQXProbe.OpenLoop.Pacer do
  @moduledoc """
  Pure open-loop schedule math for the paced stream sender.

  This is the **open-loop** measurement mode of
  [ADR-0009](../../../../docs/adr/0009-layered-benchmark-evidence-contract.md):
  payload intents are offered on a fixed **wall-clock** schedule regardless of
  whether the transport has accepted the previous offers. This is the opposite
  of the closed-loop `MOQXProbe.Traffic.Pacer`, which self-throttles its emitted
  rate to the work currently available and to a per-tick `max_burst`. The
  closed-loop pacer can never coordinated-omit because it never offers more than
  it can send; this open-loop pacer deliberately can, so that backpressure shows
  up as backlog and tick lag instead of being silently absorbed.

  The schedule is cumulative and truncation-stable: at elapsed time `t` ms the
  total number of intents that *should have been offered* is
  `floor(offered_rate * t / 1000)`. Each tick offers the difference between that
  cumulative target and what has already been offered, so integer truncation in
  one tick is repaid by the next tick rather than drifting.

  All inputs are explicit `new!/1` options. There is no `Application`
  environment and no mutable global state (CLAUDE.md hard rule). The module does
  no sending, holds no sockets, and is fully unit-testable.

  ## Modes

    * `:payload_events` (default) — `offered_rate` is in payload events per
      second and each due unit is one payload intent.
    * `:bytes` — `offered_rate` is in bytes per second and `:payload_size` (a
      positive integer) converts the byte schedule into a whole number of
      payload intents: cumulative intents are
      `floor(offered_rate * t / 1000 / payload_size)`.

  Both modes produce a per-tick **count of payload intents due**; the script
  layer turns those into actual transport sends and feeds back acceptance to
  `MOQXProbe.OpenLoop.Accounting`.
  """

  defmodule Tick do
    @moduledoc """
    One open-loop tick result. Carries the schedule view for the tick: when the
    tick was scheduled, when it actually ran, the resulting `tick_lag_ms`, the
    cumulative scheduled-intent target, and the number of payload intents
    `due_count` that the sender must offer this tick.

    `due_count` is *offered* demand, not accepted sends. The pacer never reduces
    it to match transport acceptance — that is the whole point of open loop.
    """

    @enforce_keys [
      :scheduled_at_ms,
      :now_ms,
      :tick_lag_ms,
      :elapsed_ms,
      :scheduled_total,
      :due_count
    ]
    defstruct [
      :scheduled_at_ms,
      :now_ms,
      :tick_lag_ms,
      :elapsed_ms,
      :scheduled_total,
      :due_count
    ]

    @type t :: %__MODULE__{
            scheduled_at_ms: integer(),
            now_ms: integer(),
            tick_lag_ms: integer(),
            elapsed_ms: non_neg_integer(),
            scheduled_total: non_neg_integer(),
            due_count: non_neg_integer()
          }
  end

  @enforce_keys [
    :mode,
    :offered_rate,
    :tick_ms,
    :duration_ms,
    :started_at_ms,
    :next_deadline_ms
  ]
  defstruct [
    :mode,
    :offered_rate,
    :payload_size,
    :tick_ms,
    :duration_ms,
    :started_at_ms,
    :next_deadline_ms,
    offered_total: 0,
    tick_count: 0
  ]

  @type mode :: :payload_events | :bytes

  @type t :: %__MODULE__{
          mode: mode(),
          offered_rate: pos_integer(),
          payload_size: pos_integer() | nil,
          tick_ms: pos_integer(),
          duration_ms: pos_integer(),
          started_at_ms: integer(),
          next_deadline_ms: integer(),
          offered_total: non_neg_integer(),
          tick_count: non_neg_integer()
        }

  @doc """
  Builds a pacer.

  Options:

    * `:offered_rate` (required, positive integer) — schedule rate. Payload
      events per second in `:payload_events` mode, bytes per second in `:bytes`
      mode.
    * `:tick_ms` (required, positive integer) — wall-clock tick interval.
    * `:duration_ms` (required, positive integer) — how long the schedule runs.
      The cumulative target stops growing after `started_at_ms + duration_ms`.
    * `:started_at_ms` (required, integer) — schedule origin in monotonic ms.
    * `:mode` (optional, default `:payload_events`).
    * `:payload_size` (required in `:bytes` mode, positive integer).
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    mode = mode!(opts)
    offered_rate = positive_integer!(opts, :offered_rate)
    tick_ms = positive_integer!(opts, :tick_ms)
    duration_ms = positive_integer!(opts, :duration_ms)
    started_at_ms = integer!(opts, :started_at_ms)
    payload_size = payload_size!(opts, mode)

    %__MODULE__{
      mode: mode,
      offered_rate: offered_rate,
      payload_size: payload_size,
      tick_ms: tick_ms,
      duration_ms: duration_ms,
      started_at_ms: started_at_ms,
      next_deadline_ms: started_at_ms + tick_ms
    }
  end

  @doc "The monotonic ms at which the next tick is scheduled to run."
  @spec next_deadline_ms(t()) :: integer()
  def next_deadline_ms(%__MODULE__{next_deadline_ms: next_deadline_ms}), do: next_deadline_ms

  @doc """
  The cumulative number of payload intents that should have been offered after
  `elapsed_ms` ms of wall-clock time. Clamped to the configured duration.
  """
  @spec scheduled_total(t(), non_neg_integer()) :: non_neg_integer()
  def scheduled_total(%__MODULE__{} = pacer, elapsed_ms)
      when is_integer(elapsed_ms) and elapsed_ms >= 0 do
    capped_elapsed_ms = min(elapsed_ms, pacer.duration_ms)
    scheduled_units(pacer, capped_elapsed_ms)
  end

  @doc """
  True once wall-clock `now_ms` has passed the end of the schedule window. The
  caller stops offering new intents after this; draining accepted sends is the
  script's responsibility.
  """
  @spec schedule_complete?(t(), integer()) :: boolean()
  def schedule_complete?(%__MODULE__{} = pacer, now_ms) when is_integer(now_ms) do
    now_ms >= pacer.started_at_ms + pacer.duration_ms
  end

  @doc """
  Advances the schedule to wall-clock `now_ms` and returns `{tick, pacer}`.

  `tick.due_count` is the number of payload intents the sender must offer this
  tick: `scheduled_total(now) - offered_total`. It is never reduced to match
  transport acceptance, available work, or a burst cap — open loop offers the
  full schedule and lets backlog grow when the transport cannot keep up.

  `tick.tick_lag_ms` is `now_ms - scheduled_at_ms`: how late this tick ran
  versus its scheduled wall-clock deadline. Sustained positive lag is itself a
  coordinated-omission signal (see `MOQXProbe.OpenLoop.Accounting`).
  """
  @spec tick(t(), integer()) :: {Tick.t(), t()}
  def tick(%__MODULE__{} = pacer, now_ms) when is_integer(now_ms) do
    scheduled_at_ms = pacer.next_deadline_ms
    tick_lag_ms = now_ms - scheduled_at_ms
    elapsed_ms = max(now_ms - pacer.started_at_ms, 0)
    scheduled_total = scheduled_total(pacer, elapsed_ms)
    due_count = max(scheduled_total - pacer.offered_total, 0)

    tick = %Tick{
      scheduled_at_ms: scheduled_at_ms,
      now_ms: now_ms,
      tick_lag_ms: tick_lag_ms,
      elapsed_ms: elapsed_ms,
      scheduled_total: scheduled_total,
      due_count: due_count
    }

    pacer = %{
      pacer
      | offered_total: pacer.offered_total + due_count,
        next_deadline_ms: scheduled_at_ms + pacer.tick_ms,
        tick_count: pacer.tick_count + 1
    }

    {tick, pacer}
  end

  defp scheduled_units(%__MODULE__{mode: :payload_events} = pacer, elapsed_ms) do
    div(elapsed_ms * pacer.offered_rate, 1_000)
  end

  defp scheduled_units(%__MODULE__{mode: :bytes} = pacer, elapsed_ms) do
    div(elapsed_ms * pacer.offered_rate, 1_000 * pacer.payload_size)
  end

  defp mode!(opts) do
    case Keyword.get(opts, :mode, :payload_events) do
      mode when mode in [:payload_events, :bytes] ->
        mode

      other ->
        raise ArgumentError, "mode must be :payload_events or :bytes, got #{inspect(other)}"
    end
  end

  defp payload_size!(opts, :bytes), do: positive_integer!(opts, :payload_size)

  defp payload_size!(opts, :payload_events) do
    case Keyword.fetch(opts, :payload_size) do
      {:ok, value} when is_integer(value) and value > 0 -> value
      :error -> nil
      _other -> raise ArgumentError, "payload_size must be a positive integer"
    end
  end

  defp positive_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _missing_or_invalid -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) -> value
      _missing_or_invalid -> raise ArgumentError, "#{key} must be an integer"
    end
  end
end
