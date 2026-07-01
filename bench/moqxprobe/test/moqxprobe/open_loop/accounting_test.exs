defmodule MOQXProbe.OpenLoop.AccountingTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.OpenLoop.Accounting
  alias MOQXProbe.OpenLoop.Pacer.Tick

  defp tick(due_count, tick_lag_ms, index) do
    %Tick{
      scheduled_at_ms: 1_000 + index,
      now_ms: 1_000 + index + tick_lag_ms,
      tick_lag_ms: tick_lag_ms,
      elapsed_ms: index + 1,
      scheduled_total: (index + 1) * due_count,
      due_count: due_count
    }
  end

  describe "offered/accepted/backlog bookkeeping" do
    test "accumulates offered, accepted, errors and backlog per tick" do
      acc = Accounting.new!(backlog_threshold: 1_000)

      {row, acc} = Accounting.record_tick(acc, tick(10, 0, 0), %{accepted: 10, errors: 0})
      assert row.offered_payload_events == 10
      assert row.accepted_payload_events_sender_active == 10
      assert row.backlog_payload_events == 0
      assert Accounting.backlog(acc) == 0

      {row, acc} = Accounting.record_tick(acc, tick(10, 0, 1), %{accepted: 6, errors: 1})
      assert row.offered_payload_events == 10
      assert row.accepted_payload_events_sender_active == 6
      assert row.send_admission_error_count == 1
      assert row.backlog_payload_events == 4
      assert Accounting.backlog(acc) == 4

      summary = Accounting.summary(acc)
      assert summary.offered_payload_events_total == 20
      assert summary.accepted_payload_events_sender_active_total == 16
      assert summary.send_admission_error_count == 1
      assert summary.backlog_payload_events == 4
      assert summary.max_backlog_payload_events == 4
    end

    test "out-of-band settlement reduces backlog without advancing ticks" do
      acc = Accounting.new!(backlog_threshold: 1_000)
      {_row, acc} = Accounting.record_tick(acc, tick(100, 0, 0), %{accepted: 40, errors: 0})
      assert Accounting.backlog(acc) == 60
      assert acc.tick_count == 1

      acc = Accounting.record_settlement(acc, %{accepted: 60, errors: 0})
      assert Accounting.backlog(acc) == 0
      assert acc.tick_count == 1
      assert acc.accepted_total == 100
    end

    test "tail-drain completions/cancellations are tracked without re-crediting accepted" do
      acc = Accounting.new!(backlog_threshold: 1_000)
      {_row, acc} = Accounting.record_tick(acc, tick(100, 0, 0), %{accepted: 100, errors: 0})
      assert acc.accepted_total == 100

      # Post-window drain: completions/cancellations confirm already-admitted
      # sends. They must not re-credit accepted (that would double-count), but
      # must be surfaced rather than discarded.
      acc = Accounting.record_settlement(acc, %{completed: 90, cancelled: 10})

      assert acc.accepted_total == 100
      assert acc.settled_completed_total == 90
      assert acc.settled_cancelled_total == 10

      summary = Accounting.summary(acc)
      assert summary.send_completions_drain_total == 90
      assert summary.send_cancellations_drain_total == 10
    end
  end

  describe "coordinated omission flag" do
    test "stays clear when the sender keeps up with the schedule" do
      acc = Accounting.new!(backlog_threshold: 50, sustained_lag_ms: 5, sustained_lag_ticks: 3)

      acc =
        Enum.reduce(0..19, acc, fn index, acc ->
          {_row, acc} =
            Accounting.record_tick(acc, tick(10, 0, index), %{accepted: 10, errors: 0})

          acc
        end)

      refute acc.coordinated_omission?
      assert Accounting.summary(acc).coordinated_omission == false
      assert Accounting.summary(acc).coordinated_omission_cause == nil
    end

    test "trips when backlog grows past the threshold" do
      acc =
        Accounting.new!(backlog_threshold: 50, sustained_lag_ms: 1_000, sustained_lag_ticks: 100)

      # accept nothing: backlog climbs 20 per tick, crosses 50 on the third tick.
      {_row, acc} = Accounting.record_tick(acc, tick(20, 0, 0), %{accepted: 0, errors: 0})
      refute acc.coordinated_omission?
      {_row, acc} = Accounting.record_tick(acc, tick(20, 0, 1), %{accepted: 0, errors: 0})
      refute acc.coordinated_omission?
      {row, acc} = Accounting.record_tick(acc, tick(20, 0, 2), %{accepted: 0, errors: 0})

      assert acc.coordinated_omission?
      assert acc.coordinated_omission_cause == :backlog_threshold_exceeded
      assert row.coordinated_omission == true
      assert Accounting.summary(acc).coordinated_omission_cause == "backlog_threshold_exceeded"
    end

    test "trips on sustained tick lag even when backlog stays bounded" do
      acc =
        Accounting.new!(backlog_threshold: 10_000, sustained_lag_ms: 2, sustained_lag_ticks: 3)

      # accepted keeps up (backlog bounded) but each tick runs 5ms late.
      {_row, acc} = Accounting.record_tick(acc, tick(10, 5, 0), %{accepted: 10})
      refute acc.coordinated_omission?
      {_row, acc} = Accounting.record_tick(acc, tick(10, 5, 1), %{accepted: 10})
      refute acc.coordinated_omission?
      {_row, acc} = Accounting.record_tick(acc, tick(10, 5, 2), %{accepted: 10})

      assert acc.coordinated_omission?
      assert acc.coordinated_omission_cause == :sustained_tick_lag
      assert Accounting.backlog(acc) == 0
    end

    test "a lagging streak resets when a tick runs on time" do
      acc =
        Accounting.new!(backlog_threshold: 10_000, sustained_lag_ms: 2, sustained_lag_ticks: 3)

      {_row, acc} = Accounting.record_tick(acc, tick(10, 5, 0), %{accepted: 10})
      {_row, acc} = Accounting.record_tick(acc, tick(10, 5, 1), %{accepted: 10})
      {_row, acc} = Accounting.record_tick(acc, tick(10, 0, 2), %{accepted: 10})
      assert acc.consecutive_lagging_ticks == 0
      {_row, acc} = Accounting.record_tick(acc, tick(10, 5, 3), %{accepted: 10})
      {_row, acc} = Accounting.record_tick(acc, tick(10, 5, 4), %{accepted: 10})

      refute acc.coordinated_omission?
    end

    test "the flag latches once tripped" do
      acc =
        Accounting.new!(backlog_threshold: 5, sustained_lag_ms: 1_000, sustained_lag_ticks: 100)

      {_row, acc} = Accounting.record_tick(acc, tick(10, 0, 0), %{accepted: 0})
      assert acc.coordinated_omission?

      # later ticks fully drain the backlog; the flag stays set as a run fact.
      {_row, acc} = Accounting.record_tick(acc, tick(0, 0, 1), %{accepted: 10})
      assert Accounting.backlog(acc) == 0
      assert acc.coordinated_omission?
    end
  end

  describe "warmup exclusion (issue 58)" do
    test "a lag burst inside the warmup window does not trip coordinated omission" do
      # tick/3 sets elapsed_ms = index + 1, so indices 0..4 are elapsed 1..5 ms,
      # all inside a 100 ms warmup — the startup lag must be ignored.
      acc =
        Accounting.new!(
          backlog_threshold: 10_000,
          sustained_lag_ms: 2,
          sustained_lag_ticks: 3,
          warmup_ms: 100
        )

      acc =
        Enum.reduce(0..4, acc, fn index, acc ->
          {_row, acc} = Accounting.record_tick(acc, tick(10, 30, index), %{accepted: 10})
          acc
        end)

      refute acc.coordinated_omission?
      assert acc.consecutive_lagging_ticks == 0
    end

    test "sustained lag after the warmup window still trips" do
      acc =
        Accounting.new!(
          backlog_threshold: 10_000,
          sustained_lag_ms: 2,
          sustained_lag_ticks: 3,
          warmup_ms: 3
        )

      # indices 3,4,5 => elapsed 4,5,6 ms, all past the 3 ms warmup.
      acc =
        Enum.reduce(3..5, acc, fn index, acc ->
          {_row, acc} = Accounting.record_tick(acc, tick(10, 5, index), %{accepted: 10})
          acc
        end)

      assert acc.coordinated_omission?
      assert acc.coordinated_omission_cause == :sustained_tick_lag
    end
  end

  describe "saturation verdict (issue 58)" do
    test "a completion deficit flags saturation even when the sender stayed on schedule" do
      # The 12000 ev/s reform case: no tick lag, no backlog, but the path could
      # not carry the load so admitted sends never completed.
      acc =
        Accounting.new!(
          backlog_threshold: 10_000,
          sustained_lag_ms: 1_000,
          sustained_lag_ticks: 100,
          completion_deficit_threshold: 0.01
        )

      {_row, acc} = Accounting.record_tick(acc, tick(100, 0, 0), %{accepted: 100})
      acc = Accounting.record_settlement(acc, %{completed: 90})

      summary = Accounting.summary(acc)
      refute summary.coordinated_omission
      assert summary.send_completion_deficit == 10
      assert summary.send_completion_deficit_ratio == 0.1
      assert summary.saturated == true
      assert summary.saturation_signal == "completion_deficit"
    end

    test "a fully drained run is not saturated" do
      acc = Accounting.new!(backlog_threshold: 10_000)
      {_row, acc} = Accounting.record_tick(acc, tick(100, 0, 0), %{accepted: 100})
      acc = Accounting.record_settlement(acc, %{completed: 100})

      summary = Accounting.summary(acc)
      assert summary.send_completion_deficit == 0
      assert summary.send_completion_deficit_ratio == 0.0
      refute summary.saturated
      assert summary.saturation_signal == nil
      assert summary.warmup_ms == 0
    end

    test "a backlog trip is a saturation signal" do
      acc =
        Accounting.new!(backlog_threshold: 5, sustained_lag_ms: 1_000, sustained_lag_ticks: 100)

      {_row, acc} = Accounting.record_tick(acc, tick(10, 0, 0), %{accepted: 0})
      summary = Accounting.summary(acc)

      assert summary.coordinated_omission == true
      assert summary.saturated == true
      assert summary.saturation_signal == "backlog_threshold_exceeded"
    end
  end

  describe "tick lag summary" do
    test "summarizes recorded tick lags" do
      acc = Accounting.new!(backlog_threshold: 10_000)

      acc =
        [0, 2, 4, 6, 8]
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {lag, index}, acc ->
          {_row, acc} = Accounting.record_tick(acc, tick(1, lag, index), %{accepted: 1})
          acc
        end)

      lag = Accounting.summary(acc).tick_lag_ms
      assert lag.count == 5
      assert lag.min == 0
      assert lag.max == 8
      assert lag.avg == 4.0
    end
  end
end
