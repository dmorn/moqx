defmodule MOQXProbe.Traffic.PacerTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Traffic.Pacer

  test "computes due events from absolute elapsed time" do
    pacer =
      Pacer.new!(
        count: 96_000,
        rate_per_second: 32_000,
        tick_ms: 1,
        max_burst: 128,
        started_at_ms: 1_000
      )

    assert Pacer.next_deadline_ms(pacer) == 1_001

    {tick, pacer} = Pacer.tick(pacer, 1_001)

    assert tick.scheduled_at_ms == 1_001
    assert tick.now_ms == 1_001
    assert tick.lag_ms == 0
    assert tick.target_emitted == 32
    assert tick.due_count == 32
    assert tick.send_count == 32
    refute tick.capped?
    refute tick.tool_limited?

    assert pacer.emitted_count == 32
    assert Pacer.next_deadline_ms(pacer) == 1_002
  end

  test "keeps fractional rate accounting without interval truncation drift" do
    pacer =
      Pacer.new!(
        count: 100,
        rate_per_second: 33_333,
        tick_ms: 1,
        max_burst: 128,
        started_at_ms: 5_000
      )

    {tick, pacer} = Pacer.tick(pacer, 5_001)
    assert tick.send_count == 33

    {tick, _pacer} = Pacer.tick(pacer, 5_002)
    assert tick.target_emitted == 66
    assert tick.due_count == 33
    assert tick.send_count == 33
  end

  test "caps late catch-up bursts and records the capped tick" do
    pacer =
      Pacer.new!(
        count: 96_000,
        rate_per_second: 32_000,
        tick_ms: 1,
        max_burst: 64,
        started_at_ms: 1_000
      )

    {tick, pacer} = Pacer.tick(pacer, 1_005)

    assert tick.scheduled_at_ms == 1_001
    assert tick.lag_ms == 4
    assert tick.target_emitted == 160
    assert tick.due_count == 160
    assert tick.send_count == 64
    assert tick.capped?
    refute tick.tool_limited?

    assert pacer.emitted_count == 64
    assert pacer.capped_tick_count == 1
    assert Pacer.next_deadline_ms(pacer) == 1_002
  end

  test "marks ticks as tool limited when lag exceeds the configured bound" do
    pacer =
      Pacer.new!(
        count: 96_000,
        rate_per_second: 32_000,
        tick_ms: 1,
        max_burst: 64,
        max_lag_ms: 3,
        started_at_ms: 1_000
      )

    {tick, pacer} = Pacer.tick(pacer, 1_005)

    assert tick.tool_limited?
    assert tick.stop_reason == :tool_limited
    assert tick.send_count == 0
    assert pacer.emitted_count == 0
    assert pacer.tool_limited_tick_count == 1
  end

  test "does not overshoot the configured event count" do
    pacer =
      Pacer.new!(
        count: 40,
        rate_per_second: 32_000,
        tick_ms: 1,
        max_burst: 128,
        started_at_ms: 1_000
      )

    {tick, pacer} = Pacer.tick(pacer, 1_005)

    assert tick.target_emitted == 40
    assert tick.due_count == 40
    assert tick.send_count == 40
    assert tick.stop_reason == :complete
    assert Pacer.complete?(pacer)
  end
end
