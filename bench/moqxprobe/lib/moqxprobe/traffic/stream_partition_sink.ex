defmodule MOQXProbe.Traffic.StreamPartitionSink do
  @moduledoc false

  use GenStage

  alias MOQX.Transport.Conn.Stream

  def start_link(opts) when is_list(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def snapshot(sink) do
    GenStage.call(sink, :snapshot)
  end

  def stop(sink) do
    if Process.alive?(sink) do
      Process.unlink(sink)
      GenStage.stop(sink, :normal, 1_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl GenStage
  def init(opts) do
    streams = Keyword.fetch!(opts, :streams)

    state = %{
      partition: Keyword.fetch!(opts, :partition),
      shard_index: Keyword.fetch!(opts, :shard_index),
      backend: shard_backend(streams),
      streams: stream_states(streams, opts),
      subscriptions: %{},
      upstream_closed?: false,
      source_eof_events: 0,
      producer_cancel_reasons: [],
      notify_pid: Keyword.get(opts, :notify_pid),
      max_queue_depth: Keyword.get(opts, :max_queue_depth, :infinity),
      started_at_us: monotonic_us(),
      receive_calls: 0,
      ready_drain_calls: 0,
      schedule_rounds: 0,
      payload_events: 0,
      completion_events: 0,
      send_cancelled_events: 0,
      orphan_completion_events: 0,
      ignored_events: 0,
      unknown_events: 0
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
  def handle_cancel(reason, from, state) do
    state =
      state
      |> Map.update!(:subscriptions, &Map.delete(&1, from))
      |> record_cancel_reason(reason)
      |> maybe_mark_upstream_closed()

    maybe_stop(state)
  end

  @impl GenStage
  def handle_events(events, from, state) do
    state =
      state
      |> receive_demanded_events(from, length(events))
      |> Map.update!(:receive_calls, &(&1 + 1))
      |> enqueue_payloads(events)
      |> schedule_streams()
      |> ask_for_demand()

    maybe_stop(state)
  end

  @impl GenStage
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_state(state), [], state}
  end

  @impl GenStage
  def handle_info(message, state) do
    state =
      state
      |> handle_backend_message(message)
      |> ask_for_demand()

    maybe_stop(state)
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

  defp receive_demanded_events(state, from, count) do
    update_subscription(state, from, fn subscription ->
      %{subscription | outstanding: max(subscription.outstanding - count, 0)}
    end)
  end

  defp ask_for_demand(%{upstream_closed?: true} = state), do: state

  defp ask_for_demand(%{subscriptions: subscriptions} = state) when map_size(subscriptions) == 0,
    do: state

  defp ask_for_demand(state) do
    {subscriptions, _capacity} =
      Enum.reduce(state.subscriptions, {%{}, queue_capacity(state)}, fn {from, subscription},
                                                                        {subscriptions, capacity} ->
        demand = demand_to_ask(subscription, capacity)

        if demand > 0 do
          :ok = GenStage.ask(from, demand)
          subscription = %{subscription | outstanding: subscription.outstanding + demand}
          {Map.put(subscriptions, from, subscription), subtract_capacity(capacity, demand)}
        else
          {Map.put(subscriptions, from, subscription), capacity}
        end
      end)

    %{state | subscriptions: subscriptions}
  end

  defp queue_capacity(%{max_queue_depth: :infinity}), do: :infinity

  defp queue_capacity(state) do
    max(state.max_queue_depth - total_queue_depth(state.streams) - outstanding_demand(state), 0)
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

  defp enqueue_payloads(state, events) do
    Enum.reduce(events, state, fn event, state ->
      enqueue_payload(state, event)
    end)
  end

  defp enqueue_payload(state, %{control: :source_eof}) do
    state
    |> Map.put(:upstream_closed?, true)
    |> Map.update!(:source_eof_events, &(&1 + 1))
  end

  defp enqueue_payload(state, event) do
    raw_stream = raw_stream(event.stream)

    case Map.fetch(state.streams, raw_stream) do
      {:ok, stream_state} ->
        queued = :queue.in(normalize_event(event), stream_state.queued)

        stream_state =
          stream_state
          |> Map.put(:queued, queued)
          |> Map.put(:max_queue_depth, max(stream_state.max_queue_depth, :queue.len(queued)))

        state
        |> put_stream_state(raw_stream, stream_state)
        |> Map.update!(:payload_events, &(&1 + 1))

      :error ->
        %{state | orphan_completion_events: state.orphan_completion_events + 1}
    end
  end

  defp normalize_event(%{payload: payload} = event) do
    event
    |> Map.put(:payload, payload)
    |> Map.put(:finish?, Map.get(event, :finish?, false))
  end

  defp schedule_streams(state) do
    streams =
      Map.new(state.streams, fn {raw_stream, stream_state} ->
        {raw_stream, schedule_stream(stream_state)}
      end)

    %{state | streams: streams}
    |> Map.update!(:schedule_rounds, &(&1 + 1))
  end

  defp schedule_stream(stream_state) do
    case :queue.out(stream_state.queued) do
      {{:value, event}, queued} when stream_state.in_flight < stream_state.stream_send_window ->
        stream_state
        |> Map.put(:queued, queued)
        |> send_event(event)
        |> schedule_stream()

      {{:value, event}, queued} ->
        %{stream_state | queued: :queue.in_r(event, queued)}

      {:empty, _queued} ->
        stream_state
    end
  end

  defp send_event(stream_state, event) do
    opts = if event.finish?, do: [finish: true], else: []
    {:ok, _send, sender} = Stream.Sender.send(stream_state.sender, event.payload, opts)
    in_flight = stream_state.in_flight + 1

    %{
      stream_state
      | sender: sender,
        accepted: stream_state.accepted + 1,
        in_flight: in_flight,
        max_in_flight: max(stream_state.max_in_flight, in_flight),
        send_calls: stream_state.send_calls + 1
    }
  end

  defp handle_backend_message(%{backend: nil} = state, _message) do
    %{state | unknown_events: state.unknown_events + 1}
  end

  defp handle_backend_message(state, message) do
    case state.backend.normalize_message(message) do
      {:stream_event, raw_stream, :send_complete, false} ->
        complete_stream(state, raw_stream)

      {:stream_event, raw_stream, :send_complete, true} ->
        cancel_stream(state, raw_stream)

      {:stream_event, raw_stream, _event, _metadata} ->
        update_stream_event(state, raw_stream, :ignored_events)

      :unknown ->
        %{state | unknown_events: state.unknown_events + 1}

      _event ->
        %{state | ignored_events: state.ignored_events + 1}
    end
  end

  defp complete_stream(state, raw_stream) do
    state
    |> update_stream_event(raw_stream, :completion_events, fn stream_state ->
      case pop_pending_send(stream_state.sender) do
        {:ok, sender} ->
          %{
            stream_state
            | sender: sender,
              completed: stream_state.completed + 1,
              in_flight: max(stream_state.in_flight - 1, 0)
          }
          |> schedule_stream()

        :empty ->
          stream_state
      end
    end)
    |> Map.update!(:schedule_rounds, &(&1 + 1))
  end

  defp cancel_stream(state, raw_stream) do
    state
    |> update_stream_event(raw_stream, :send_cancelled_events, fn stream_state ->
      case pop_pending_send(stream_state.sender) do
        {:ok, sender} ->
          %{stream_state | sender: sender, in_flight: max(stream_state.in_flight - 1, 0)}
          |> schedule_stream()

        :empty ->
          stream_state
      end
    end)
    |> Map.update!(:schedule_rounds, &(&1 + 1))
  end

  defp update_stream_event(
         state,
         raw_stream,
         counter,
         fun \\ fn stream_state -> stream_state end
       ) do
    case Map.fetch(state.streams, raw_stream) do
      {:ok, stream_state} ->
        state
        |> put_stream_state(raw_stream, fun.(stream_state))
        |> increment_counter(counter)

      :error ->
        %{state | orphan_completion_events: state.orphan_completion_events + 1}
    end
  end

  defp increment_counter(state, :completion_events),
    do: %{state | completion_events: state.completion_events + 1}

  defp increment_counter(state, :send_cancelled_events),
    do: %{state | send_cancelled_events: state.send_cancelled_events + 1}

  defp increment_counter(state, :ignored_events),
    do: %{state | ignored_events: state.ignored_events + 1}

  defp put_stream_state(state, raw_stream, stream_state) do
    %{state | streams: Map.put(state.streams, raw_stream, stream_state)}
  end

  defp pop_pending_send(sender) do
    case :queue.out(sender.pending_sends) do
      {{:value, _send}, remaining} -> {:ok, %{sender | pending_sends: remaining}}
      {:empty, _queue} -> :empty
    end
  end

  defp maybe_stop(state) do
    if complete?(state) do
      snapshot = snapshot_state(state)
      if is_pid(state.notify_pid), do: send(state.notify_pid, done_message(self(), snapshot))
      {:stop, :normal, state}
    else
      {:noreply, [], state}
    end
  end

  defp complete?(state) do
    state.upstream_closed? and total_queue_depth(state.streams) == 0 and
      total_in_flight(state.streams) == 0 and
      completed_count(state.streams) >= expected_count(state)
  end

  defp done_message(pid, snapshot) do
    {:moqxprobe_stream_partition_sink_done, pid, snapshot.partition, snapshot}
  end

  defp record_cancel_reason(state, reason) when reason in [:normal, :shutdown] do
    state
  end

  defp record_cancel_reason(state, {:shutdown, _reason}) do
    state
  end

  defp record_cancel_reason(state, reason) do
    %{state | producer_cancel_reasons: [inspect(reason) | state.producer_cancel_reasons]}
  end

  defp maybe_mark_upstream_closed(%{subscriptions: subscriptions} = state) do
    if map_size(subscriptions) == 0 do
      %{state | upstream_closed?: true}
    else
      state
    end
  end

  defp snapshot_state(state) do
    stream_results = Map.values(state.streams)

    %{
      partition: state.partition,
      shard_index: state.shard_index,
      stream_count: length(stream_results),
      accepted: sum_field(stream_results, :accepted),
      completed: sum_field(stream_results, :completed),
      in_flight: sum_field(stream_results, :in_flight),
      max_in_flight: max_field(stream_results, :max_in_flight),
      max_queue_depth: max_field(stream_results, :max_queue_depth),
      queue_depth: total_queue_depth(state.streams),
      outstanding_demand: outstanding_demand(state),
      max_sink_queue_depth: queue_depth_value(state.max_queue_depth),
      send_calls: sum_field(stream_results, :send_calls),
      payload_events: state.payload_events,
      source_eof_events: state.source_eof_events,
      completion_events: state.completion_events,
      send_cancelled_events: state.send_cancelled_events,
      orphan_completion_events: state.orphan_completion_events,
      ignored_events: state.ignored_events,
      unknown_events: state.unknown_events,
      receive_calls: state.receive_calls,
      ready_drain_calls: state.ready_drain_calls,
      schedule_rounds: state.schedule_rounds,
      upstream_closed?: state.upstream_closed?,
      producer_cancel_reasons: Enum.reverse(state.producer_cancel_reasons),
      expected: expected_count(state),
      duration_us: monotonic_us() - state.started_at_us
    }
  end

  defp stream_states(streams, opts) do
    payload_count = Keyword.fetch!(opts, :payload_count)
    stream_send_window = Keyword.fetch!(opts, :stream_send_window)

    Map.new(streams, fn %{stream: stream, index: index} ->
      {:ok, sender} = Stream.sender(stream)

      {raw_stream(stream),
       %{
         sender: sender,
         stream_index: index,
         payload_count: payload_count,
         stream_send_window: stream_send_window,
         accepted: 0,
         completed: 0,
         in_flight: 0,
         max_in_flight: 0,
         queued: :queue.new(),
         max_queue_depth: 0,
         send_calls: 0
       }}
    end)
  end

  defp shard_backend([%{stream: %Stream{backend: backend}} | _streams]), do: backend.module
  defp shard_backend([]), do: nil

  defp raw_stream(%Stream{backend: %{data: raw_stream}}), do: raw_stream

  defp total_queue_depth(streams) do
    streams
    |> Map.values()
    |> Enum.map(&:queue.len(&1.queued))
    |> Enum.sum()
  end

  defp total_in_flight(streams) do
    streams
    |> Map.values()
    |> sum_field(:in_flight)
  end

  defp completed_count(streams) do
    streams
    |> Map.values()
    |> sum_field(:completed)
  end

  defp expected_count(state) do
    state.streams
    |> Map.values()
    |> Enum.map(& &1.payload_count)
    |> Enum.sum()
  end

  defp sum_field(values, field) do
    values
    |> map_field(field)
    |> Enum.sum()
  end

  defp max_field(values, field) do
    values
    |> map_field(field)
    |> max_value()
  end

  defp map_field(values, field), do: Enum.map(values, &Map.fetch!(&1, field))

  defp max_value([]), do: nil
  defp max_value(values), do: Enum.max(values)

  defp queue_depth_value(:infinity), do: :infinity
  defp queue_depth_value(value), do: value

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

  defp monotonic_us, do: System.monotonic_time(:microsecond)
end
