defmodule MOQXProbe.OpenLoop.PacerTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.OpenLoop.Pacer

  describe "schedule cumulative intent count" do
    test "offers floor(rate * elapsed) intents at each tick" do
      pacer =
        Pacer.new!(
          offered_rate: 32_000,
          tick_ms: 1,
          duration_ms: 10_000,
          started_at_ms: 1_000
        )

      assert Pacer.next_deadline_ms(pacer) == 1_001

      {tick, pacer} = Pacer.tick(pacer, 1_001)

      assert tick.scheduled_at_ms == 1_001
      assert tick.tick_lag_ms == 0
      assert tick.elapsed_ms == 1
      assert tick.scheduled_total == 32
      assert tick.due_count == 32
      assert pacer.offered_total == 32
      assert Pacer.next_deadline_ms(pacer) == 1_002

      {tick, pacer} = Pacer.tick(pacer, 1_002)
      assert tick.scheduled_total == 64
      assert tick.due_count == 32
      assert pacer.offered_total == 64
    end

    test "cumulative target is truncation-stable across ticks" do
      pacer =
        Pacer.new!(
          offered_rate: 33_333,
          tick_ms: 1,
          duration_ms: 10_000,
          started_at_ms: 5_000
        )

      {tick, pacer} = Pacer.tick(pacer, 5_001)
      assert tick.scheduled_total == 33
      assert tick.due_count == 33

      {tick, pacer} = Pacer.tick(pacer, 5_002)
      assert tick.scheduled_total == 66
      assert tick.due_count == 33

      {tick, _pacer} = Pacer.tick(pacer, 5_003)
      assert tick.scheduled_total == 99
      assert tick.due_count == 33
    end

    test "cumulative target matches floor(rate * elapsed / 1000) over a long run" do
      offered_rate = 12_345
      tick_ms = 5
      duration_ms = 2_000

      pacer =
        Pacer.new!(
          offered_rate: offered_rate,
          tick_ms: tick_ms,
          duration_ms: duration_ms,
          started_at_ms: 0
        )

      {final, total} =
        Enum.reduce(1..400, {pacer, 0}, fn n, {pacer, _total} ->
          now = n * tick_ms
          {tick, pacer} = Pacer.tick(pacer, now)
          expected = div(min(now, duration_ms) * offered_rate, 1_000)
          assert tick.scheduled_total == expected
          assert pacer.offered_total == expected
          {pacer, pacer.offered_total}
        end)

      assert final.offered_total == total
      assert total == div(duration_ms * offered_rate, 1_000)
    end
  end

  describe "open-loop semantics" do
    test "offers the full backlog on a late tick (no burst cap, no throttle)" do
      pacer =
        Pacer.new!(
          offered_rate: 32_000,
          tick_ms: 1,
          duration_ms: 10_000,
          started_at_ms: 1_000
        )

      # tick runs 5ms late: the schedule does not slow down, all 160 intents
      # scheduled by now are offered at once.
      {tick, pacer} = Pacer.tick(pacer, 1_005)

      assert tick.scheduled_at_ms == 1_001
      assert tick.tick_lag_ms == 4
      assert tick.scheduled_total == 160
      assert tick.due_count == 160
      assert pacer.offered_total == 160
    end

    test "stops growing the cumulative target after the duration window" do
      pacer =
        Pacer.new!(
          offered_rate: 1_000,
          tick_ms: 100,
          duration_ms: 500,
          started_at_ms: 0
        )

      assert Pacer.scheduled_total(pacer, 500) == 500
      assert Pacer.scheduled_total(pacer, 600) == 500
      refute Pacer.schedule_complete?(pacer, 499)
      assert Pacer.schedule_complete?(pacer, 500)
    end
  end

  describe "bytes mode" do
    test "converts a byte schedule into whole payload intents" do
      pacer =
        Pacer.new!(
          mode: :bytes,
          offered_rate: 1_180_000,
          payload_size: 1_180,
          tick_ms: 10,
          duration_ms: 10_000,
          started_at_ms: 0
        )

      # 1_180_000 bytes/s / 1180 bytes = 1000 events/s -> 10 events per 10ms.
      {tick, _pacer} = Pacer.tick(pacer, 10)
      assert tick.scheduled_total == 10
      assert tick.due_count == 10
    end

    test "requires payload_size in bytes mode" do
      assert_raise ArgumentError, fn ->
        Pacer.new!(
          mode: :bytes,
          offered_rate: 1_000,
          tick_ms: 1,
          duration_ms: 10,
          started_at_ms: 0
        )
      end
    end
  end
end
