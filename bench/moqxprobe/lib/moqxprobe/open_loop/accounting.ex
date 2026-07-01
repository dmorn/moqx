defmodule MOQXProbe.OpenLoop.Accounting do
  @moduledoc """
  Pure offered-vs-accepted bookkeeping and coordinated-omission detection for
  the open-loop paced stream sender.

  This module owns the part of the
  [ADR-0009](../../../../docs/adr/0009-layered-benchmark-evidence-contract.md)
  open-loop contract that does not need sockets: per-tick and run-summary
  accounting of **offered** payload events (what the schedule demanded),
  **accepted** payload events (what the transport admitted for sending),
  **send-admission errors**, **backlog** (offered minus accepted), **tick lag**
  (scheduled tick time vs actual tick time), and the post-window **tail-drain**
  send completions/cancellations (`record_settlement/2`) that confirm
  already-admitted sends. It also raises a
  `coordinated_omission?` flag when the sender falls behind its schedule — when
  backlog grows past a threshold or tick lag is sustained past a `warmup_ms`
  window. That flag is a *sender-scheduling* signal, not a saturation verdict:
  on a buffered QUIC sender the schedule can be met while the path drops the
  excess. The trustworthy saturation verdict is `saturated` (issue 58), driven
  by the **completion deficit** (admitted sends that never completed) or a
  backlog trip — not by tick lag alone.

  Detect only. This module does **not** compute a corrected latency histogram;
  latency correction is deferred to issue 56. It records the *fact* that
  coordinated omission occurred so a corrected reading can be built later.

  Metric naming follows the ADR-0009 rule (source layer + numerator +
  denominator/window). The sender-layer per-second views are derived in the
  script from these raw counts over the `sender_active` window; this module
  keeps raw counts and explicit windows and never derives a naked
  bandwidth/goodput and never reports stream `pkts/s`.

  All inputs are explicit. No `Application` environment, no mutable global
  state, no IO. Fully unit-testable.
  """

  alias MOQXProbe.OpenLoop.Pacer.Tick

  @enforce_keys [:backlog_threshold, :sustained_lag_ms, :sustained_lag_ticks]
  defstruct backlog_threshold: nil,
            sustained_lag_ms: nil,
            sustained_lag_ticks: nil,
            warmup_ms: 0,
            completion_deficit_threshold: 0.01,
            offered_total: 0,
            accepted_total: 0,
            error_total: 0,
            settled_completed_total: 0,
            settled_cancelled_total: 0,
            tick_count: 0,
            max_backlog: 0,
            max_tick_lag_ms: 0,
            consecutive_lagging_ticks: 0,
            coordinated_omission?: false,
            coordinated_omission_cause: nil,
            tick_lags_ms: []

  @type cause :: :backlog_threshold_exceeded | :sustained_tick_lag
  @type saturation_signal :: :completion_deficit | :backlog_threshold_exceeded

  @type t :: %__MODULE__{
          backlog_threshold: pos_integer(),
          sustained_lag_ms: non_neg_integer(),
          sustained_lag_ticks: pos_integer(),
          warmup_ms: non_neg_integer(),
          completion_deficit_threshold: float(),
          offered_total: non_neg_integer(),
          accepted_total: non_neg_integer(),
          error_total: non_neg_integer(),
          settled_completed_total: non_neg_integer(),
          settled_cancelled_total: non_neg_integer(),
          tick_count: non_neg_integer(),
          max_backlog: non_neg_integer(),
          max_tick_lag_ms: integer(),
          consecutive_lagging_ticks: non_neg_integer(),
          coordinated_omission?: boolean(),
          coordinated_omission_cause: cause() | nil,
          tick_lags_ms: [integer()]
        }

  @doc """
  Builds the accounting state.

  Options:

    * `:backlog_threshold` (required, positive integer) — coordinated omission
      trips when current backlog (`offered_total - accepted_total`) exceeds this
      value.
    * `:sustained_lag_ms` (optional, non-negative integer, default `0`) — a tick
      is "lagging" when its `tick_lag_ms` exceeds this bound.
    * `:sustained_lag_ticks` (optional, positive integer, default `3`) —
      coordinated omission trips after this many consecutive lagging ticks.
    * `:warmup_ms` (optional, non-negative integer, default `0`) — ticks whose
      `elapsed_ms` is below this bound are excluded from the lag-streak
      evaluation, so connection setup / TLS / first-send jitter cannot
      false-trip the sustained-tick-lag flag. Backlog trips are unaffected.
    * `:completion_deficit_threshold` (optional, float in `(0, 1]`, default
      `0.01`) — the `saturated` verdict fires when the fraction of admitted
      sends that never completed exceeds this bound.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    %__MODULE__{
      backlog_threshold: positive_integer!(opts, :backlog_threshold),
      sustained_lag_ms: non_negative_integer!(opts, :sustained_lag_ms, 0),
      sustained_lag_ticks: positive_integer_with_default!(opts, :sustained_lag_ticks, 3),
      warmup_ms: non_negative_integer!(opts, :warmup_ms, 0),
      completion_deficit_threshold: ratio_with_default!(opts, :completion_deficit_threshold, 0.01)
    }
  end

  @doc "Current backlog: offered intents the transport has not yet accepted."
  @spec backlog(t()) :: non_neg_integer()
  def backlog(%__MODULE__{offered_total: offered, accepted_total: accepted}) do
    max(offered - accepted, 0)
  end

  @doc """
  Records one tick's outcome and returns `{tick_row, accounting}`.

    * `tick` — the `MOQXProbe.OpenLoop.Pacer.Tick` for this tick (carries the
      offered `due_count` and `tick_lag_ms`).
    * `outcome` — a map/keyword with `:accepted` (payload events the transport
      admitted this tick) and `:errors` (send-admission errors this tick).

  The returned `tick_row` is the per-tick sidecar shape (ADR-0009 metric names,
  raw counts, explicit windows). The flag may trip during this call and stays
  tripped (latched) for the rest of the run.
  """
  @spec record_tick(t(), Tick.t(), map() | keyword()) :: {map(), t()}
  def record_tick(%__MODULE__{} = acc, %Tick{} = tick, outcome) do
    accepted = fetch_count(outcome, :accepted)
    errors = fetch_count(outcome, :errors)

    offered_total = acc.offered_total + tick.due_count
    accepted_total = acc.accepted_total + accepted
    error_total = acc.error_total + errors
    backlog = max(offered_total - accepted_total, 0)

    # Ticks inside the warmup window never count toward the lag streak, so
    # connection-setup jitter cannot false-trip sustained tick lag. A warmup
    # tick resets the streak (treated as non-lagging).
    in_warmup? = tick.elapsed_ms < acc.warmup_ms
    lagging? = not in_warmup? and tick.tick_lag_ms > acc.sustained_lag_ms
    consecutive_lagging_ticks = if lagging?, do: acc.consecutive_lagging_ticks + 1, else: 0

    acc = %{
      acc
      | offered_total: offered_total,
        accepted_total: accepted_total,
        error_total: error_total,
        tick_count: acc.tick_count + 1,
        max_backlog: max(acc.max_backlog, backlog),
        max_tick_lag_ms: max(acc.max_tick_lag_ms, tick.tick_lag_ms),
        consecutive_lagging_ticks: consecutive_lagging_ticks,
        tick_lags_ms: [tick.tick_lag_ms | acc.tick_lags_ms]
    }

    acc = maybe_trip(acc, backlog, consecutive_lagging_ticks)

    tick_row = %{
      record_type: "tick",
      window: "sender_active",
      source_layer: "sender",
      tick_index: acc.tick_count - 1,
      scheduled_at_ms: tick.scheduled_at_ms,
      now_ms: tick.now_ms,
      elapsed_ms: tick.elapsed_ms,
      scheduled_total: tick.scheduled_total,
      offered_payload_events: tick.due_count,
      accepted_payload_events_sender_active: accepted,
      send_admission_error_count: errors,
      backlog_payload_events: backlog,
      tick_lag_ms: tick.tick_lag_ms,
      offered_payload_events_total: offered_total,
      accepted_payload_events_total: accepted_total,
      coordinated_omission: acc.coordinated_omission?
    }

    {tick_row, acc}
  end

  @doc """
  Records out-of-band deltas that arrived between ticks, for example send
  completions/cancellations drained after the schedule window. Does not advance
  the tick count or sample tick lag, but does update backlog and can latch the
  flag.

  `outcome` keys (all optional, non-negative):

    * `:accepted` — late send admissions that the transport reported after the
      offer (deferred-admission transports). These reduce backlog the same way a
      tick admission does.
    * `:errors` — late send-admission errors.
    * `:completed` — send completions of already-admitted sends drained during
      the tail window. These do **not** re-credit `accepted` (the send was
      already counted at admission time); they are tracked separately so the
      tail drain is explicit rather than silently discarded.
    * `:cancelled` — send cancellations of already-admitted sends drained during
      the tail window. Tracked separately for the same reason.
  """
  @spec record_settlement(t(), map() | keyword()) :: t()
  def record_settlement(%__MODULE__{} = acc, outcome) do
    accepted = fetch_count(outcome, :accepted)
    errors = fetch_count(outcome, :errors)
    completed = fetch_count(outcome, :completed)
    cancelled = fetch_count(outcome, :cancelled)

    accepted_total = acc.accepted_total + accepted
    error_total = acc.error_total + errors
    backlog = max(acc.offered_total - accepted_total, 0)

    %{
      acc
      | accepted_total: accepted_total,
        error_total: error_total,
        settled_completed_total: acc.settled_completed_total + completed,
        settled_cancelled_total: acc.settled_cancelled_total + cancelled,
        max_backlog: max(acc.max_backlog, backlog)
    }
    |> maybe_trip(backlog, acc.consecutive_lagging_ticks)
  end

  @doc """
  The run-summary row for the sidecar. Raw counts and explicit windows only
  (ADR-0009); no derived rate, no naked bandwidth/goodput, no stream `pkts/s`.
  The script layer derives the `sender_active` per-second views from these
  counts and the measured window width.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = acc) do
    # tick_lags_ms is accumulated newest-first; order does not matter here since
    # lag_summary/1 sorts, so it is used as-is (no reverse).
    lags = acc.tick_lags_ms

    deficit = send_completion_deficit(acc)
    deficit_ratio = send_completion_deficit_ratio(acc, deficit)
    {saturated?, signal} = saturation_verdict(acc, deficit_ratio)

    %{
      record_type: "summary",
      window: "sender_active",
      source_layer: "sender",
      warmup_ms: acc.warmup_ms,
      tick_count: acc.tick_count,
      offered_payload_events_total: acc.offered_total,
      accepted_payload_events_sender_active_total: acc.accepted_total,
      send_admission_error_count: acc.error_total,
      send_completions_drain_total: acc.settled_completed_total,
      send_cancellations_drain_total: acc.settled_cancelled_total,
      # Completion deficit: admitted sends the transport never completed. On a
      # buffered QUIC sender this is the trustworthy saturation signal — the
      # sender can stay on schedule while the path drops the excess, so tick lag
      # alone misses it (ADR-0009 / issue 58).
      send_completion_deficit: deficit,
      send_completion_deficit_ratio: deficit_ratio,
      saturated: saturated?,
      saturation_signal: encode_signal(signal),
      backlog_payload_events: backlog(acc),
      max_backlog_payload_events: acc.max_backlog,
      # `max_tick_lag_ms` is a running maximum seeded at 0, so it never reports a
      # negative lag; `tick_lag_ms` (below) summarizes the raw per-tick lags and
      # may report a negative min/max for a run that stayed ahead of schedule.
      # The two `max` values can therefore differ for an all-early run.
      max_tick_lag_ms: acc.max_tick_lag_ms,
      tick_lag_ms: lag_summary(lags),
      # `coordinated_omission` is the raw sender-scheduling signal (tick lag or
      # backlog). It is NOT the saturation verdict: a warmup-suppressed or purely
      # jittery lag trip does not mean the path saturated. Use `saturated`.
      coordinated_omission: acc.coordinated_omission?,
      coordinated_omission_cause: encode_cause(acc.coordinated_omission_cause)
    }
  end

  # Admitted sends that never reported completion during the run + tail drain.
  defp send_completion_deficit(%__MODULE__{} = acc) do
    max(acc.accepted_total - acc.settled_completed_total, 0)
  end

  defp send_completion_deficit_ratio(%__MODULE__{accepted_total: 0}, _deficit), do: 0.0

  defp send_completion_deficit_ratio(%__MODULE__{accepted_total: accepted}, deficit) do
    deficit / accepted
  end

  # The trustworthy saturation verdict: the transport/path could not carry the
  # offered load. Driven by the completion deficit or an offered-vs-accepted
  # backlog trip — not by sender-schedule tick lag alone.
  defp saturation_verdict(%__MODULE__{} = acc, deficit_ratio) do
    cond do
      deficit_ratio > acc.completion_deficit_threshold ->
        {true, :completion_deficit}

      acc.coordinated_omission_cause == :backlog_threshold_exceeded ->
        {true, :backlog_threshold_exceeded}

      true ->
        {false, nil}
    end
  end

  defp maybe_trip(%__MODULE__{coordinated_omission?: true} = acc, _backlog, _lagging), do: acc

  defp maybe_trip(%__MODULE__{} = acc, backlog, consecutive_lagging_ticks) do
    cond do
      backlog > acc.backlog_threshold ->
        %{
          acc
          | coordinated_omission?: true,
            coordinated_omission_cause: :backlog_threshold_exceeded
        }

      consecutive_lagging_ticks >= acc.sustained_lag_ticks ->
        %{acc | coordinated_omission?: true, coordinated_omission_cause: :sustained_tick_lag}

      true ->
        acc
    end
  end

  defp lag_summary([]), do: %{count: 0, min: nil, avg: nil, max: nil, p95: nil}

  defp lag_summary(lags) do
    count = length(lags)
    sorted = Enum.sort(lags)
    index = max(ceil(count * 0.95) - 1, 0)

    # min/max come from the sorted list rather than separate Enum.min/max passes.
    %{
      count: count,
      min: List.first(sorted),
      avg: Enum.sum(lags) / count,
      max: List.last(sorted),
      p95: Enum.at(sorted, index)
    }
  end

  defp fetch_count(outcome, key) when is_map(outcome),
    do: normalize_count(Map.get(outcome, key, 0))

  defp fetch_count(outcome, key) when is_list(outcome),
    do: normalize_count(Keyword.get(outcome, key, 0))

  defp normalize_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_count(_value), do: 0

  defp encode_cause(nil), do: nil
  defp encode_cause(cause) when is_atom(cause), do: Atom.to_string(cause)

  defp encode_signal(nil), do: nil
  defp encode_signal(signal) when is_atom(signal), do: Atom.to_string(signal)

  defp positive_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _missing_or_invalid -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp positive_integer_with_default!(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> value
      :error -> default
      _invalid -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp non_negative_integer!(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> value
      :error -> default
      _invalid -> raise ArgumentError, "#{key} must be a non-negative integer"
    end
  end

  defp ratio_with_default!(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) and value > 0 and value <= 1 -> value / 1
      :error -> default
      _invalid -> raise ArgumentError, "#{key} must be a number in (0, 1]"
    end
  end
end
