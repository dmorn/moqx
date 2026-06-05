defmodule MOQXProbe.Traffic.DatagramSenderTest do
  use ExUnit.Case, async: false

  alias MOQXProbe.Traffic.DatagramSender

  @telemetry_events [
    [:moqx, :transport_bench, :datagram_sender, :run, :start],
    [:moqx, :transport_bench, :datagram_sender, :run, :stop],
    [:moqx, :transport_bench, :datagram_sender, :demand, :ask],
    [:moqx, :transport_bench, :datagram_sender, :backlog, :change],
    [:moqx, :transport_bench, :datagram_sender, :tick, :stop],
    [:moqx, :transport_bench, :datagram_sender, :send, :error]
  ]

  test "runs a bounded descriptor producer into the final DATAGRAM sink process" do
    parent = self()

    send_fun = fn %{sequence: sequence, padding: padding}, state ->
      send(parent, {:sent, self(), sequence, byte_size(padding)})
      {:ok, [sequence | state]}
    end

    assert {:ok, snapshot} =
             DatagramSender.run(
               count: 4,
               rate_per_second: 2_000,
               started_at_us: 1_000_000,
               payload_mode: {:sequence_timestamp, 64},
               send_fun: send_fun,
               transport_state: [],
               now_fun: monotonic_ms_counter(1_000),
               timer_fun: immediate_timer(),
               max_burst: 2,
               min_demand: 1,
               max_demand: 2,
               max_queue_depth: 2
             )

    assert %{
             accepted: 4,
             errors: 0,
             queue_depth: 0,
             outstanding_demand: 0,
             max_queue_depth: 2,
             stop_reason: :complete,
             payload_producer_result: :ok
           } = snapshot

    sent = receive_sent(4, [])
    assert Enum.map(sent, fn {_pid, sequence, _padding_size} -> sequence end) == [1, 2, 3, 4]
    assert Enum.all?(sent, fn {_pid, _sequence, padding_size} -> padding_size == 48 end)

    sender_pids = sent |> Enum.map(fn {pid, _sequence, _padding_size} -> pid end) |> Enum.uniq()
    assert sender_pids != [parent]
    assert length(sender_pids) == 1
  end

  test "emits benchmark telemetry for lifecycle, demand, backlog, and ticks" do
    attach_telemetry()

    send_fun = fn payload, sent ->
      if payload == "bad" do
        {:error, :blocked, sent}
      else
        {:ok, [payload | sent]}
      end
    end

    assert {:ok, snapshot} =
             DatagramSender.run(
               count: 2,
               rate_per_second: 2_000,
               started_at_us: 1_000_000,
               mapper: fn
                 1 -> "ok"
                 2 -> "bad"
               end,
               send_fun: send_fun,
               transport_state: [],
               now_fun: monotonic_ms_counter(1_000),
               timer_fun: immediate_timer(),
               max_burst: 2,
               min_demand: 1,
               max_demand: 2,
               max_queue_depth: 2
             )

    assert %{accepted: 1, errors: 1, stop_reason: :complete} = snapshot

    assert_receive {:telemetry, [:moqx, :transport_bench, :datagram_sender, :run, :start],
                    %{count: 2, rate_per_second: 2_000, max_burst: 2}, %{sender: :datagram}}

    assert_receive {:telemetry, [:moqx, :transport_bench, :datagram_sender, :demand, :ask],
                    %{demand_count: 2, max_queue_depth: 2}, %{sender: :datagram}}

    assert_telemetry(
      [:moqx, :transport_bench, :datagram_sender, :backlog, :change],
      fn measurements, metadata ->
        measurements[:queue_depth] == 2 and metadata[:sink] == :datagram_sink
      end
    )

    assert_telemetry(
      [:moqx, :transport_bench, :datagram_sender, :tick, :stop],
      fn measurements, metadata ->
        measurements[:due_count] == 2 and measurements[:send_count] == 2 and
          measurements[:accepted_count] == 1 and measurements[:error_count] == 1 and
          measurements[:capped_tick_count] == 0 and is_integer(measurements[:burst_duration_us]) and
          metadata[:result] == :error
      end
    )

    assert_receive {:telemetry, [:moqx, :transport_bench, :datagram_sender, :send, :error],
                    %{error_count: 1}, %{error_reasons: [":blocked"]}}

    assert_receive {:telemetry, [:moqx, :transport_bench, :datagram_sender, :run, :stop],
                    %{accepted_count: 1, error_count: 1, queue_depth: 0},
                    %{result: :ok, stop_reason: :complete}}
  end

  defp receive_sent(0, sent), do: Enum.reverse(sent)

  defp receive_sent(count, sent) do
    receive do
      {:sent, pid, sequence, padding_size} ->
        receive_sent(count - 1, [{pid, sequence, padding_size} | sent])
    after
      100 ->
        flunk("expected #{count} more sent payloads")
    end
  end

  defp monotonic_ms_counter(start_ms) do
    {:ok, clock} = Agent.start_link(fn -> start_ms end)

    fn ->
      Agent.get_and_update(clock, fn now_ms ->
        next_ms = now_ms + 1
        {next_ms, next_ms}
      end)
    end
  end

  defp immediate_timer do
    fn ref, _deadline_ms ->
      send(self(), {:traffic_datagram_sink_tick, ref})
      :ok
    end
  end

  defp attach_telemetry do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        @telemetry_events,
        &__MODULE__.handle_telemetry/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def handle_telemetry(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  defp assert_telemetry(event, predicate, remaining \\ 20)

  defp assert_telemetry(event, predicate, remaining) when remaining > 0 do
    receive do
      {:telemetry, ^event, measurements, metadata} ->
        if predicate.(measurements, metadata) do
          :ok
        else
          assert_telemetry(event, predicate, remaining - 1)
        end
    after
      100 ->
        flunk("expected telemetry event #{inspect(event)}")
    end
  end

  defp assert_telemetry(event, _predicate, 0) do
    flunk("expected matching telemetry event #{inspect(event)}")
  end
end
