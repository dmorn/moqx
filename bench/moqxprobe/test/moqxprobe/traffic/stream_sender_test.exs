defmodule MOQXProbe.Traffic.StreamSenderTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Traffic.StreamSender

  test "runs payload flow through the final stream sink across repeated runs" do
    assert {:ok, first} = run_sender(:first)
    assert {:ok, second} = run_sender(:second)

    assert first.accepted == 3
    assert first.stop_reason == :complete
    assert second.accepted == 3
    assert second.stop_reason == :complete

    assert_receive {:sent, :first, 1, false}
    assert_receive {:sent, :first, 2, false}
    assert_receive {:sent, :first, 3, true}
    assert_receive {:sent, :second, 1, false}
    assert_receive {:sent, :second, 2, false}
    assert_receive {:sent, :second, 3, true}
  end

  test "send completion feedback reopens the per-stream send window" do
    parent = self()
    stream = %{stream: {:stream, make_ref()}, index: 1}

    send_fun = fn event, transport_state ->
      send(parent, {:sent, event.payload_index, event.finish?})
      {:ok, make_ref(), transport_state}
    end

    assert {:ok, sender} =
             StreamSender.start(
               count: 2,
               started_at_us: System.monotonic_time(:microsecond),
               streams: [stream],
               payload: "x",
               payload_count: 2,
               stream_send_window: 1,
               send_fun: send_fun,
               transport_state: %{},
               idle_retries: 1_000
             )

    assert {:ok, snapshot} = StreamSender.drain(sender)
    assert snapshot.accepted == 1
    assert snapshot.queue_depth == 1
    assert snapshot.in_flight == 1
    assert snapshot.stop_reason == nil
    assert_receive {:sent, 1, false}

    assert {:ok, snapshot} = StreamSender.complete(sender, stream.stream, 1)
    assert snapshot.accepted == 2
    assert snapshot.completed == 1
    assert snapshot.queue_depth == 0
    assert snapshot.stop_reason == :complete
    assert_receive {:sent, 2, true}

    assert {:ok, _snapshot} = StreamSender.finish(sender)
  end

  test "bounds producer demand by configured queue depth before draining" do
    stream = %{stream: {:stream, make_ref()}, index: 1}

    assert {:ok, sender} =
             StreamSender.start(
               count: 100,
               started_at_us: System.monotonic_time(:microsecond),
               streams: [stream],
               payload: "x",
               payload_count: 100,
               stream_send_window: 100,
               send_fun: fn _event, transport_state -> {:ok, make_ref(), transport_state} end,
               transport_state: %{},
               max_burst: 4,
               max_demand: 4,
               max_queue_depth: 4,
               idle_retries: 1_000
             )

    snapshot =
      wait_until(fn ->
        snapshot = StreamSender.snapshot(sender)

        if snapshot.queue_depth > 0 do
          {:ok, snapshot}
        else
          :cont
        end
      end)

    assert snapshot.accepted == 0
    assert snapshot.queue_depth <= 4
    assert snapshot.max_queue_depth == 4

    assert {:ok, _snapshot} = StreamSender.stop(sender)
  end

  defp run_sender(label) do
    parent = self()
    streams = [%{stream: {:stream, label}, index: 1}]

    send_fun = fn event, transport_state ->
      send(parent, {:sent, label, event.payload_index, event.finish?})
      {:ok, make_ref(), transport_state}
    end

    StreamSender.run(
      count: 3,
      started_at_us: System.monotonic_time(:microsecond),
      streams: streams,
      payload: "x",
      payload_count: 3,
      stream_send_window: 3,
      send_fun: send_fun,
      transport_state: %{},
      idle_retries: 1_000
    )
  end

  defp wait_until(fun, retries \\ 50)

  defp wait_until(fun, retries) when retries > 0 do
    case fun.() do
      {:ok, value} ->
        value

      :cont ->
        Process.sleep(1)
        wait_until(fun, retries - 1)
    end
  end

  defp wait_until(fun, 0) do
    case fun.() do
      {:ok, value} -> value
      :cont -> flunk("condition was not met before timeout")
    end
  end
end
