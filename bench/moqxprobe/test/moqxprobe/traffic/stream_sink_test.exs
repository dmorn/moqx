defmodule MOQXProbe.Traffic.StreamSinkTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Traffic.Pacer
  alias MOQXProbe.Traffic.StreamSink

  test "respects per-stream send windows before admitting more payloads" do
    parent = self()

    send_fun = fn stream, payload, opts, next_token ->
      send(parent, {:sent, stream, payload, opts, next_token})
      {:ok, next_token, next_token + 1}
    end

    {:ok, sink} =
      StreamSink.start_link(
        pacer:
          Pacer.new!(
            count: 2,
            rate_per_second: 2_000,
            tick_ms: 1,
            max_burst: 2,
            started_at_ms: 1_000
          ),
        send_fun: send_fun,
        transport_state: 1,
        stream_send_window: 1
      )

    :ok =
      StreamSink.enqueue(sink, [
        %{stream: :s1, payload: "a", finish?: false},
        %{stream: :s1, payload: "b", finish?: true}
      ])

    tick = StreamSink.tick(sink, 1_001)

    assert tick.send_count == 1
    assert tick.stream_window_limited?
    assert_receive {:sent, :s1, "a", [], 1}

    assert %{accepted: 1, in_flight: 1, queue_depth: 1, stop_reason: nil} =
             StreamSink.snapshot(sink)

    :ok = StreamSink.complete(sink, :s1, 1)

    tick = StreamSink.tick(sink, 1_002)

    assert tick.send_count == 1
    assert tick.stop_reason == :complete
    assert_receive {:sent, :s1, "b", [finish: true], 2}

    assert %{
             accepted: 2,
             completed: 1,
             in_flight: 1,
             queue_depth: 0,
             stop_reason: :complete
           } = StreamSink.snapshot(sink)
  end

  test "counts stream send errors and does not keep failed sends in flight" do
    send_fun = fn
      :s1, "bad", _opts, state -> {:error, :blocked, state}
      _stream, _payload, _opts, state -> {:ok, make_ref(), state}
    end

    {:ok, sink} =
      StreamSink.start_link(
        pacer:
          Pacer.new!(
            count: 2,
            rate_per_second: 2_000,
            tick_ms: 1,
            max_burst: 2,
            started_at_ms: 1_000
          ),
        send_fun: send_fun,
        stream_send_window: 2
      )

    :ok =
      StreamSink.enqueue(sink, [
        %{stream: :s1, payload: "ok", finish?: false},
        %{stream: :s1, payload: "bad", finish?: true}
      ])

    tick = StreamSink.tick(sink, 1_001)

    assert tick.stop_reason == :complete

    assert %{
             accepted: 1,
             errors: 1,
             error_reasons: %{":blocked" => 1},
             in_flight: 1,
             queue_depth: 0,
             stop_reason: :complete
           } = StreamSink.snapshot(sink)
  end

  test "runs its own pacing loop while stream completions reopen the send window" do
    parent = self()
    {:ok, clock} = Agent.start_link(fn -> [1_001, 1_002] end)

    now_fun = fn ->
      Agent.get_and_update(clock, fn [now | rest] -> {now, rest} end)
    end

    timer_fun = fn ref, _deadline_ms ->
      send(self(), {:traffic_stream_sink_tick, ref})
      :ok
    end

    send_fun = fn stream, payload, opts, state ->
      send(parent, {:sent, stream, payload, opts})
      send(self(), {:traffic_stream_sink_completed, stream, 1})
      {:ok, state, state}
    end

    {:ok, sink} =
      StreamSink.start_link(
        pacer:
          Pacer.new!(
            count: 2,
            rate_per_second: 2_000,
            tick_ms: 1,
            max_burst: 2,
            started_at_ms: 1_000
          ),
        send_fun: send_fun,
        transport_state: :token,
        stream_send_window: 1,
        now_fun: now_fun,
        timer_fun: timer_fun
      )

    :ok =
      StreamSink.enqueue(sink, [
        %{stream: :s1, payload: "a", finish?: false},
        %{stream: :s1, payload: "b", finish?: true}
      ])

    assert %{
             accepted: 2,
             completed: 1,
             errors: 0,
             queue_depth: 0,
             stop_reason: :complete
           } = StreamSink.run(sink)

    assert_receive {:sent, :s1, "a", []}
    assert_receive {:sent, :s1, "b", [finish: true]}
  end
end
