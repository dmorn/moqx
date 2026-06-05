defmodule MOQXProbe.Traffic.DatagramSinkTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Traffic.DatagramSink
  alias MOQXProbe.Traffic.Pacer

  test "sends due datagrams from the sink queue" do
    parent = self()

    send_fun = fn payload, sent ->
      send(parent, {:sent, payload})
      {:ok, [payload | sent]}
    end

    {:ok, sink} =
      DatagramSink.start_link(
        pacer:
          Pacer.new!(
            count: 5,
            rate_per_second: 5_000,
            tick_ms: 1,
            max_burst: 3,
            started_at_ms: 1_000
          ),
        send_fun: send_fun,
        transport_state: []
      )

    :ok = DatagramSink.enqueue(sink, ["a", "b", "c", "d", "e"])

    tick = DatagramSink.tick(sink, 1_001)
    assert tick.send_count == 3
    assert tick.capped?

    assert_receive {:sent, "a"}
    assert_receive {:sent, "b"}
    assert_receive {:sent, "c"}

    assert %{accepted: 3, errors: 0, queue_depth: 2, stop_reason: nil} =
             DatagramSink.snapshot(sink)

    tick = DatagramSink.tick(sink, 1_002)
    assert tick.send_count == 2
    assert tick.stop_reason == :complete

    assert_receive {:sent, "d"}
    assert_receive {:sent, "e"}

    assert %{
             accepted: 5,
             errors: 0,
             queue_depth: 0,
             stop_reason: :complete,
             burst_counts: [3, 2]
           } = DatagramSink.snapshot(sink)
  end

  test "counts send errors without retrying the same datagram" do
    send_fun = fn
      "bad", state -> {:error, :blocked, state}
      payload, state -> {:ok, [payload | state]}
    end

    {:ok, sink} =
      DatagramSink.start_link(
        pacer:
          Pacer.new!(
            count: 3,
            rate_per_second: 3_000,
            tick_ms: 1,
            max_burst: 3,
            started_at_ms: 1_000
          ),
        send_fun: send_fun,
        transport_state: []
      )

    :ok = DatagramSink.enqueue(sink, ["ok-1", "bad", "ok-2"])

    tick = DatagramSink.tick(sink, 1_001)

    assert tick.stop_reason == :complete

    assert %{
             accepted: 2,
             errors: 1,
             error_reasons: %{":blocked" => 1},
             queue_depth: 0,
             stop_reason: :complete
           } = DatagramSink.snapshot(sink)
  end

  test "can stop a burst on the first send error" do
    send_fun = fn
      "bad", state -> {:error, :blocked, state}
      payload, state -> {:ok, [payload | state]}
    end

    {:ok, sink} =
      DatagramSink.start_link(
        pacer:
          Pacer.new!(
            count: 3,
            rate_per_second: 3_000,
            tick_ms: 1,
            max_burst: 3,
            started_at_ms: 1_000
          ),
        send_fun: send_fun,
        transport_state: [],
        stop_on_error?: true
      )

    :ok = DatagramSink.enqueue(sink, ["ok-1", "bad", "not-sent"])

    tick = DatagramSink.tick(sink, 1_001)

    assert tick.stop_reason == :send_error

    assert %{
             accepted: 1,
             errors: 1,
             error_reasons: %{":blocked" => 1},
             queue_depth: 1,
             stop_reason: :send_error
           } = DatagramSink.snapshot(sink)
  end

  test "stops before sending when the pacer marks the run tool limited" do
    parent = self()

    send_fun = fn payload, state ->
      send(parent, {:unexpected_send, payload})
      {:ok, state}
    end

    {:ok, sink} =
      DatagramSink.start_link(
        pacer:
          Pacer.new!(
            count: 3,
            rate_per_second: 3_000,
            tick_ms: 1,
            max_burst: 3,
            max_lag_ms: 2,
            started_at_ms: 1_000
          ),
        send_fun: send_fun
      )

    :ok = DatagramSink.enqueue(sink, ["a", "b", "c"])

    tick = DatagramSink.tick(sink, 1_004)

    assert tick.tool_limited?
    assert tick.stop_reason == :tool_limited
    refute_received {:unexpected_send, _payload}

    assert %{
             accepted: 0,
             errors: 0,
             queue_depth: 3,
             stop_reason: :tool_limited
           } = DatagramSink.snapshot(sink)
  end

  test "runs its own absolute-timer pacing loop until completion" do
    parent = self()
    {:ok, clock} = Agent.start_link(fn -> [1_001, 1_002] end)

    now_fun = fn ->
      Agent.get_and_update(clock, fn [now | rest] -> {now, rest} end)
    end

    timer_fun = fn ref, _deadline_ms ->
      send(self(), {:traffic_datagram_sink_tick, ref})
      :ok
    end

    send_fun = fn payload, state ->
      send(parent, {:sent, payload})
      {:ok, [payload | state]}
    end

    {:ok, sink} =
      DatagramSink.start_link(
        pacer:
          Pacer.new!(
            count: 4,
            rate_per_second: 2_000,
            tick_ms: 1,
            max_burst: 2,
            started_at_ms: 1_000
          ),
        send_fun: send_fun,
        transport_state: [],
        now_fun: now_fun,
        timer_fun: timer_fun
      )

    :ok = DatagramSink.enqueue(sink, ["a", "b", "c", "d"])

    assert %{accepted: 4, errors: 0, stop_reason: :complete, burst_counts: [2, 2]} =
             DatagramSink.run(sink)

    assert_receive {:sent, "a"}
    assert_receive {:sent, "b"}
    assert_receive {:sent, "c"}
    assert_receive {:sent, "d"}
  end
end
