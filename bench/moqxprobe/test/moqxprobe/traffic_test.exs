defmodule MOQXProbe.TrafficTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Traffic
  alias MOQXProbe.Traffic.DatagramSink
  alias MOQXProbe.Traffic.Pacer

  test "feeds Flow-produced payloads into a GenStage sink" do
    {:ok, sink} =
      DatagramSink.start_link(
        pacer:
          Pacer.new!(
            count: 2,
            rate_per_second: 2_000,
            tick_ms: 1,
            max_burst: 2,
            started_at_ms: 1_000
          ),
        send_fun: fn _payload, state -> {:ok, state} end
      )

    assert :ok =
             Traffic.feed_payloads(1..2, sink,
               mapper: fn sequence -> "payload-#{sequence}" end,
               stages: 1,
               min_demand: 1,
               max_demand: 2
             )

    assert %{queue_depth: 2} = DatagramSink.snapshot(sink)
  end

  test "bounds Flow-produced payload backlog by sink queue capacity" do
    {:ok, sink} =
      DatagramSink.start_link(
        pacer:
          Pacer.new!(
            count: 5,
            rate_per_second: 2_000,
            tick_ms: 1,
            max_burst: 2,
            started_at_ms: 1_000
          ),
        send_fun: fn _payload, state -> {:ok, state} end,
        max_queue_depth: 2
      )

    assert {:ok, producer} =
             Traffic.start_payloads(1..5, sink,
               mapper: fn sequence -> "payload-#{sequence}" end,
               stages: 1,
               min_demand: 1,
               max_demand: 2
             )

    assert %{queue_depth: 2, outstanding_demand: 0, max_queue_depth: 2} =
             wait_for_snapshot(sink, &(&1.queue_depth == 2))

    ref = Process.monitor(producer)
    refute_receive {:DOWN, ^ref, :process, ^producer, _reason}, 20

    assert %{send_count: 2} = DatagramSink.tick(sink, 1_001)

    assert %{queue_depth: 2, outstanding_demand: 0} =
             wait_for_snapshot(sink, &(&1.queue_depth == 2))

    assert %{send_count: 2} = DatagramSink.tick(sink, 1_002)

    snapshot = wait_for_snapshot(sink, &(&1.queue_depth == 1))
    assert snapshot.queue_depth + snapshot.outstanding_demand <= snapshot.max_queue_depth

    assert %{send_count: 1, stop_reason: :complete} = DatagramSink.tick(sink, 1_003)
    assert :ok = Traffic.await_payloads(producer, 1_000)

    Process.demonitor(ref, [:flush])
  end

  defp wait_for_snapshot(sink, predicate, attempts \\ 50)

  defp wait_for_snapshot(sink, predicate, attempts) when attempts > 0 do
    snapshot = DatagramSink.snapshot(sink)

    if predicate.(snapshot) do
      snapshot
    else
      Process.sleep(5)
      wait_for_snapshot(sink, predicate, attempts - 1)
    end
  end

  defp wait_for_snapshot(sink, _predicate, 0), do: DatagramSink.snapshot(sink)
end
