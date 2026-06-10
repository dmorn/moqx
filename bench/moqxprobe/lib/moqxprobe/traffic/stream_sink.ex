defmodule MOQXProbe.Traffic.StreamSink do
  @moduledoc false

  use GenStage

  alias MOQXProbe.Traffic.Pacer

  @telemetry_prefix [:moqx, :transport_bench, :stream_sender]

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

  def complete_many(sink, completions) when is_list(completions) do
    GenStage.call(sink, {:complete_many, completions})
  end

  def snapshot(sink) do
    GenStage.call(sink, :snapshot)
  end

  def update_transport_state(sink, fun) when is_function(fun, 1) do
    GenStage.call(sink, {:update_transport_state, fun})
  end

  def run(sink, timeout \\ :infinity) do
    GenStage.call(sink, :run, timeout)
  end

  @impl GenStage
  def init(opts) do
    state = %{
      pacer: Keyword.fetch!(opts, :pacer),
      queue: :queue.new(),
      max_queue_depth: Keyword.get(opts, :max_queue_depth, :infinity),
      subscriptions: %{},
      send_fun: Keyword.fetch!(opts, :send_fun),
      complete_fun: Keyword.get(opts, :complete_fun, &default_complete_fun/3),
      transport_state: Keyword.get(opts, :transport_state),
      event_forward_pid: Keyword.get(opts, :event_forward_pid),
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
  def handle_subscribe(:producer, opts, from, state) do
    state =
      state
      |> put_subscription(from, opts)
      |> ask_for_demand()

    {:manual, state}
  end

  @impl GenStage
  def handle_cancel(_reason, from, state) do
    {:noreply, [], %{state | subscriptions: Map.delete(state.subscriptions, from)}}
  end

  @impl GenStage
  def handle_events(events, from, state) do
    state =
      state
      |> receive_demanded_events(from, length(events))
      |> enqueue_events(events)
      |> ask_for_demand()

    {:noreply, [], state}
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

  def handle_call({:complete_many, completions}, _from, state) do
    {:reply, :ok, [], complete_many_stream_sends(state, completions)}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_state(state), [], state}
  end

  def handle_call({:update_transport_state, fun}, _from, state) do
    {:reply, :ok, [], %{state | transport_state: fun.(state.transport_state)}}
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

  def handle_info(message, %{event_forward_pid: pid} = state) when is_pid(pid) do
    send(pid, message)
    {:noreply, [], state}
  end

  defp enqueue_events(state, events) do
    queue =
      Enum.reduce(events, state.queue, fn event, queue ->
        :queue.in(normalize_event(event), queue)
      end)

    state = %{state | queue: queue}
    emit_backlog(state, length(events))
    state
  end

  defp normalize_event(%{stream: stream, payload: payload} = event) do
    event
    |> Map.put(:stream, stream)
    |> Map.put(:payload, payload)
    |> Map.put(:finish?, Map.get(event, :finish?, false))
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

    emit_tick(state, tick, actual_send_count, accepted, errors, duration_us)
    emit_send_errors(error_reasons, errors)

    state =
      if stop_reason do
        state
      else
        ask_for_demand(state)
      end

    {tick, state}
  end

  defp put_subscription(state, from, opts) do
    max_demand = positive_subscription_integer(opts, :max_demand, default_max_demand(state))
    min_demand = non_negative_subscription_integer(opts, :min_demand, max(max_demand - 1, 0))

    subscription = %{
      outstanding: 0,
      max_demand: max_demand,
      min_demand: min(min_demand, max(max_demand - 1, 0))
    }

    %{state | subscriptions: Map.put(state.subscriptions, from, subscription)}
  end

  defp default_max_demand(%{max_queue_depth: :infinity}), do: 1_000
  defp default_max_demand(%{max_queue_depth: max_queue_depth}), do: max(max_queue_depth, 1)

  defp positive_subscription_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp non_negative_subscription_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end

  defp receive_demanded_events(state, from, count) do
    update_subscription(state, from, fn subscription ->
      %{subscription | outstanding: max(subscription.outstanding - count, 0)}
    end)
  end

  defp ask_for_demand(%{subscriptions: subscriptions} = state)
       when map_size(subscriptions) == 0 do
    state
  end

  defp ask_for_demand(%{stop_reason: stop_reason} = state) when not is_nil(stop_reason), do: state

  defp ask_for_demand(state) do
    {subscriptions, _capacity} =
      Enum.reduce(state.subscriptions, {%{}, queue_capacity(state)}, fn {from, subscription},
                                                                        {subscriptions, capacity} ->
        demand = demand_to_ask(subscription, capacity)

        if demand > 0 do
          :ok = GenStage.ask(from, demand)

          subscription = %{
            subscription
            | outstanding: subscription.outstanding + demand
          }

          emit_demand(state, subscription, demand)
          {Map.put(subscriptions, from, subscription), subtract_capacity(capacity, demand)}
        else
          {Map.put(subscriptions, from, subscription), capacity}
        end
      end)

    %{state | subscriptions: subscriptions}
  end

  defp queue_capacity(%{max_queue_depth: :infinity}), do: :infinity

  defp queue_capacity(state) do
    max(state.max_queue_depth - :queue.len(state.queue) - outstanding_demand(state), 0)
  end

  defp outstanding_demand(state) do
    state.subscriptions
    |> Map.values()
    |> Enum.map(& &1.outstanding)
    |> Enum.sum()
  end

  defp demand_to_ask(%{outstanding: outstanding, min_demand: min_demand}, _capacity)
       when outstanding > min_demand,
       do: 0

  defp demand_to_ask(subscription, :infinity), do: subscription.max_demand

  defp demand_to_ask(subscription, capacity), do: min(subscription.max_demand, capacity)

  defp subtract_capacity(:infinity, _demand), do: :infinity
  defp subtract_capacity(capacity, demand), do: max(capacity - demand, 0)

  defp update_subscription(state, from, fun) do
    case Map.fetch(state.subscriptions, from) do
      {:ok, subscription} ->
        %{state | subscriptions: Map.put(state.subscriptions, from, fun.(subscription))}

      :error ->
        state
    end
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

          case send_event(state.send_fun, event, opts, transport_state) do
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

  defp send_event(send_fun, event, opts, transport_state) do
    case :erlang.fun_info(send_fun, :arity) do
      {:arity, 2} -> send_fun.(event, transport_state)
      {:arity, 4} -> send_fun.(event.stream, event.payload, opts, transport_state)
    end
  end

  defp complete_stream_sends(state, stream, count) do
    state
    |> do_complete_stream_sends(stream, count)
    |> ask_for_demand()
  end

  defp complete_many_stream_sends(state, []), do: state

  defp complete_many_stream_sends(state, completions) do
    state =
      Enum.reduce(completions, state, fn {stream, count}, state ->
        do_complete_stream_sends(state, stream, count)
      end)

    ask_for_demand(state)
  end

  defp do_complete_stream_sends(state, stream, count) do
    streams =
      Map.update(state.streams, stream, %{in_flight: 0}, fn stream_state ->
        %{stream_state | in_flight: max(stream_state.in_flight - count, 0)}
      end)

    transport_state = state.complete_fun.(stream, count, state.transport_state)

    state
    |> Map.put(:streams, streams)
    |> Map.put(:transport_state, transport_state)
    |> Map.update!(:completed, &(&1 + count))
  end

  defp default_complete_fun(_stream, _count, transport_state), do: transport_state

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
      outstanding_demand: outstanding_demand(state),
      max_queue_depth: state.max_queue_depth,
      stream_send_window: state.stream_send_window,
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

  defp emit_backlog(state, enqueued_count) do
    :telemetry.execute(
      @telemetry_prefix ++ [:backlog, :change],
      %{
        enqueued_count: enqueued_count,
        queue_depth: :queue.len(state.queue),
        outstanding_demand: outstanding_demand(state),
        max_queue_depth: telemetry_queue_depth(state.max_queue_depth)
      },
      %{sender: :stream, sink: :stream_sink}
    )
  end

  defp emit_demand(state, subscription, demand) do
    :telemetry.execute(
      @telemetry_prefix ++ [:demand, :ask],
      %{
        demand_count: demand,
        outstanding_demand: subscription.outstanding,
        queue_depth: :queue.len(state.queue),
        max_queue_depth: telemetry_queue_depth(state.max_queue_depth)
      },
      %{sender: :stream, sink: :stream_sink}
    )
  end

  defp emit_tick(state, tick, actual_send_count, accepted, errors, duration_us) do
    :telemetry.execute(
      @telemetry_prefix ++ [:tick, :stop],
      %{
        lag_ms: tick.lag_ms,
        due_count: tick.due_count,
        target_emitted: tick.target_emitted,
        send_count: actual_send_count,
        accepted_count: accepted,
        error_count: errors,
        capped_tick_count: flag(tick.capped?),
        tool_limited_tick_count: flag(tick.tool_limited?),
        stream_window_limited_tick_count: flag(tick.stream_window_limited?),
        burst_duration_us: duration_us,
        queue_depth: :queue.len(state.queue),
        outstanding_demand: outstanding_demand(state),
        in_flight: total_in_flight(state.streams)
      },
      %{
        sender: :stream,
        sink: :stream_sink,
        result: tick_result(tick, errors),
        stop_reason: tick.stop_reason
      }
    )
  end

  defp emit_send_errors(_error_reasons, 0), do: :ok

  defp emit_send_errors(error_reasons, errors) do
    :telemetry.execute(
      @telemetry_prefix ++ [:send, :error],
      %{error_count: errors},
      %{sender: :stream, sink: :stream_sink, error_reasons: Map.keys(error_reasons)}
    )
  end

  defp telemetry_queue_depth(:infinity), do: -1
  defp telemetry_queue_depth(max_queue_depth), do: max_queue_depth

  defp flag(true), do: 1
  defp flag(false), do: 0

  defp tick_result(_tick, errors) when errors > 0, do: :error
  defp tick_result(%{stop_reason: :tool_limited}, _errors), do: :tool_limited
  defp tick_result(%{stop_reason: :complete}, _errors), do: :complete
  defp tick_result(_tick, _errors), do: :ok

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
