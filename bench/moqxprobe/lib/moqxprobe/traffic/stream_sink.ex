defmodule MOQXProbe.Traffic.StreamSink do
  @moduledoc false

  use GenStage

  alias MOQXProbe.Traffic.Pacer

  def start_link(opts) when is_list(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def enqueue(sink, payloads) when is_list(payloads) do
    GenStage.call(sink, {:enqueue, payloads})
  end

  def tick(sink, now_ms) when is_integer(now_ms) do
    GenStage.call(sink, {:tick, now_ms})
  end

  def complete(sink, stream, count \\ 1) when is_integer(count) and count >= 0 do
    GenStage.call(sink, {:complete, stream, count})
  end

  def snapshot(sink) do
    GenStage.call(sink, :snapshot)
  end

  def run(sink, timeout \\ :infinity) do
    GenStage.call(sink, :run, timeout)
  end

  @impl GenStage
  def init(opts) do
    state = %{
      pacer: Keyword.fetch!(opts, :pacer),
      queue: :queue.new(),
      send_fun: Keyword.fetch!(opts, :send_fun),
      transport_state: Keyword.get(opts, :transport_state),
      now_fun: Keyword.get(opts, :now_fun, &monotonic_ms/0),
      timer_fun: Keyword.get(opts, :timer_fun, &schedule_tick/2),
      runner_from: nil,
      run_ref: nil,
      stream_send_window: Keyword.get(opts, :stream_send_window, 16),
      streams: %{},
      accepted: 0,
      completed: 0,
      errors: 0,
      error_reasons: %{},
      burst_counts: [],
      burst_durations_us: [],
      tick_lags_ms: [],
      tick_due_counts: [],
      tick_send_counts: [],
      stream_window_limited_tick_count: 0,
      stop_reason: nil
    }

    {:consumer, state}
  end

  @impl GenStage
  def handle_events(events, _from, state) do
    {:noreply, [], enqueue_events(state, events)}
  end

  @impl GenStage
  def handle_call({:enqueue, payloads}, _from, state) do
    {:reply, :ok, [], enqueue_events(state, payloads)}
  end

  def handle_call({:tick, now_ms}, _from, state) do
    {tick, state} = send_tick(state, now_ms)

    {:reply, tick, [], state}
  end

  def handle_call({:complete, stream, count}, _from, state) do
    {:reply, :ok, [], complete_stream_sends(state, stream, count)}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_state(state), [], state}
  end

  def handle_call(:run, _from, %{stop_reason: stop_reason} = state)
      when not is_nil(stop_reason) do
    {:reply, snapshot_state(state), [], state}
  end

  def handle_call(:run, from, state) do
    ref = make_ref()
    state = %{state | runner_from: from, run_ref: ref}

    :ok = state.timer_fun.(ref, Pacer.next_deadline_ms(state.pacer))

    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info({:traffic_stream_sink_tick, ref}, %{run_ref: ref} = state) do
    now_ms = state.now_fun.()
    {_tick, state} = send_tick(state, now_ms)

    if state.stop_reason do
      GenStage.reply(state.runner_from, snapshot_state(state))
      {:noreply, [], %{state | runner_from: nil, run_ref: nil}}
    else
      :ok = state.timer_fun.(ref, Pacer.next_deadline_ms(state.pacer))
      {:noreply, [], state}
    end
  end

  def handle_info({:traffic_stream_sink_tick, _ref}, state) do
    {:noreply, [], state}
  end

  def handle_info({:traffic_stream_sink_completed, stream, count}, state)
      when is_integer(count) and count >= 0 do
    {:noreply, [], complete_stream_sends(state, stream, count)}
  end

  defp enqueue_events(state, events) do
    queue =
      Enum.reduce(events, state.queue, fn event, queue ->
        :queue.in(normalize_event(event), queue)
      end)

    %{state | queue: queue}
  end

  defp normalize_event(%{stream: stream, payload: payload} = event) do
    %{stream: stream, payload: payload, finish?: Map.get(event, :finish?, false)}
  end

  defp send_tick(%{stop_reason: stop_reason} = state, _now_ms) when not is_nil(stop_reason) do
    {%{send_count: 0, stop_reason: stop_reason, stream_window_limited?: false}, state}
  end

  defp send_tick(state, now_ms) do
    sendable =
      sendable_count(state.queue, state.streams, state.stream_send_window, state.pacer.max_burst)

    window_limited? = :queue.len(state.queue) > sendable
    {pacer_tick, pacer} = Pacer.tick(state.pacer, now_ms, sendable)

    {events, queue} =
      take_sendable(state.queue, state.streams, state.stream_send_window, pacer_tick.send_count)

    {accepted, errors, error_reasons, streams, transport_state, duration_us} =
      send_events(events, state)

    actual_send_count = accepted + errors
    stop_reason = stop_reason(pacer_tick)

    state =
      state
      |> Map.put(:pacer, pacer)
      |> Map.put(:queue, queue)
      |> Map.put(:streams, streams)
      |> Map.put(:transport_state, transport_state)
      |> Map.update!(:accepted, &(&1 + accepted))
      |> Map.update!(:errors, &(&1 + errors))
      |> merge_error_reasons(error_reasons)
      |> Map.update!(:tick_lags_ms, &[pacer_tick.lag_ms | &1])
      |> Map.update!(:tick_due_counts, &[pacer_tick.due_count | &1])
      |> Map.update!(:tick_send_counts, &[actual_send_count | &1])
      |> maybe_record_burst(actual_send_count, duration_us)
      |> maybe_increment(:stream_window_limited_tick_count, window_limited?)
      |> Map.put(:stop_reason, stop_reason)

    tick =
      pacer_tick
      |> Map.from_struct()
      |> Map.put(:send_count, actual_send_count)
      |> Map.put(:stop_reason, stop_reason)
      |> Map.put(:stream_window_limited?, window_limited?)

    {tick, state}
  end

  defp sendable_count(queue, streams, stream_send_window, limit) do
    queue
    |> :queue.to_list()
    |> count_sendable(streams, stream_send_window, limit, 0)
  end

  defp count_sendable(_events, _streams, _stream_send_window, limit, count) when count >= limit,
    do: count

  defp count_sendable([], _streams, _stream_send_window, _limit, count), do: count

  defp count_sendable([event | events], streams, stream_send_window, limit, count) do
    if sendable?(event, streams, stream_send_window) do
      streams = increment_in_flight(streams, event.stream)
      count_sendable(events, streams, stream_send_window, limit, count + 1)
    else
      count_sendable(events, streams, stream_send_window, limit, count)
    end
  end

  defp take_sendable(queue, streams, stream_send_window, count) do
    {selected, kept, _streams} =
      queue
      |> :queue.to_list()
      |> Enum.reduce({[], [], streams}, fn event, {selected, kept, streams} ->
        if length(selected) < count and sendable?(event, streams, stream_send_window) do
          {[event | selected], kept, increment_in_flight(streams, event.stream)}
        else
          {selected, [event | kept], streams}
        end
      end)

    queue = kept |> Enum.reverse() |> :queue.from_list()

    {Enum.reverse(selected), queue}
  end

  defp sendable?(event, streams, stream_send_window) do
    stream_in_flight(streams, event.stream) < stream_send_window
  end

  defp send_events([], state) do
    {0, 0, %{}, state.streams, state.transport_state, 0}
  end

  defp send_events(events, state) do
    started_at = monotonic_us()

    {accepted, errors, error_reasons, streams, transport_state} =
      Enum.reduce(
        events,
        {0, 0, %{}, state.streams, state.transport_state},
        fn event, {accepted, errors, reasons, streams, transport_state} ->
          opts = if event.finish?, do: [finish: true], else: []

          case state.send_fun.(event.stream, event.payload, opts, transport_state) do
            {:ok, _send, transport_state} ->
              {accepted + 1, errors, reasons, increment_in_flight(streams, event.stream),
               transport_state}

            {:error, reason, transport_state} ->
              {accepted, errors + 1, increment_error_reason(reasons, reason), streams,
               transport_state}
          end
        end
      )

    {accepted, errors, error_reasons, streams, transport_state, monotonic_us() - started_at}
  end

  defp complete_stream_sends(state, stream, count) do
    streams =
      Map.update(state.streams, stream, %{in_flight: 0}, fn stream_state ->
        %{stream_state | in_flight: max(stream_state.in_flight - count, 0)}
      end)

    state
    |> Map.put(:streams, streams)
    |> Map.update!(:completed, &(&1 + count))
  end

  defp increment_in_flight(streams, stream) do
    Map.update(streams, stream, %{in_flight: 1}, fn stream_state ->
      %{stream_state | in_flight: stream_state.in_flight + 1}
    end)
  end

  defp stream_in_flight(streams, stream) do
    streams
    |> Map.get(stream, %{in_flight: 0})
    |> Map.fetch!(:in_flight)
  end

  defp stop_reason(%{tool_limited?: true}), do: :tool_limited
  defp stop_reason(%{stop_reason: :complete}), do: :complete
  defp stop_reason(_tick), do: nil

  defp maybe_record_burst(state, 0, _duration_us), do: state

  defp maybe_record_burst(state, count, duration_us) do
    state
    |> Map.update!(:burst_counts, &[count | &1])
    |> Map.update!(:burst_durations_us, &[duration_us | &1])
  end

  defp maybe_increment(state, key, true), do: Map.update!(state, key, &(&1 + 1))
  defp maybe_increment(state, _key, false), do: state

  defp merge_error_reasons(state, error_reasons) do
    Map.update!(state, :error_reasons, fn existing ->
      Map.merge(existing, error_reasons, fn _reason, left, right -> left + right end)
    end)
  end

  defp increment_error_reason(error_reasons, reason) do
    Map.update(error_reasons, inspect(reason), 1, &(&1 + 1))
  end

  defp snapshot_state(state) do
    %{
      accepted: state.accepted,
      completed: state.completed,
      errors: state.errors,
      error_reasons: state.error_reasons,
      in_flight: total_in_flight(state.streams),
      queue_depth: :queue.len(state.queue),
      stop_reason: state.stop_reason,
      transport_state: state.transport_state,
      pacer: state.pacer,
      burst_counts: Enum.reverse(state.burst_counts),
      burst_durations_us: Enum.reverse(state.burst_durations_us),
      tick_lags_ms: Enum.reverse(state.tick_lags_ms),
      tick_due_counts: Enum.reverse(state.tick_due_counts),
      tick_send_counts: Enum.reverse(state.tick_send_counts),
      stream_window_limited_tick_count: state.stream_window_limited_tick_count
    }
  end

  defp total_in_flight(streams) do
    streams
    |> Map.values()
    |> Enum.map(& &1.in_flight)
    |> Enum.sum()
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp schedule_tick(ref, deadline_ms) do
    Process.send_after(self(), {:traffic_stream_sink_tick, ref}, deadline_ms, abs: true)
    :ok
  end
end
