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
end
