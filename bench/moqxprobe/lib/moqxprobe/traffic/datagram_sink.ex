defmodule MOQXProbe.Traffic.DatagramSink do
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
      stop_on_error?: Keyword.get(opts, :stop_on_error?, false),
      now_fun: Keyword.get(opts, :now_fun, &monotonic_ms/0),
      timer_fun: Keyword.get(opts, :timer_fun, &schedule_tick/2),
      runner_from: nil,
      run_ref: nil,
      accepted: 0,
      errors: 0,
      error_reasons: %{},
      burst_counts: [],
      burst_durations_us: [],
      tick_lags_ms: [],
      tick_due_counts: [],
      tick_send_counts: [],
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
  def handle_info({:traffic_datagram_sink_tick, ref}, %{run_ref: ref} = state) do
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

  def handle_info({:traffic_datagram_sink_tick, _ref}, state) do
    {:noreply, [], state}
  end

  defp enqueue_events(state, events) do
    queue = Enum.reduce(events, state.queue, fn event, queue -> :queue.in(event, queue) end)

    %{state | queue: queue}
  end

  defp send_tick(%{stop_reason: stop_reason} = state, _now_ms) when not is_nil(stop_reason) do
    {%Pacer.Tick{send_count: 0, stop_reason: stop_reason}, state}
  end

  defp send_tick(state, now_ms) do
    {tick, pacer} = Pacer.tick(state.pacer, now_ms, :queue.len(state.queue))
    {payloads, queue} = pop_many(state.queue, tick.send_count)

    {accepted, errors, error_reasons, transport_state, duration_us, stopped_on_error?} =
      send_payloads(payloads, state.send_fun, state.transport_state, state.stop_on_error?)

    actual_send_count = accepted + errors
    stop_reason = stop_reason(tick, actual_send_count, stopped_on_error?)
    queue = restore_unsent_payloads(queue, payloads, actual_send_count)

    state =
      state
      |> Map.put(:pacer, pacer)
      |> Map.put(:queue, queue)
      |> Map.put(:transport_state, transport_state)
      |> Map.update!(:accepted, &(&1 + accepted))
      |> Map.update!(:errors, &(&1 + errors))
      |> merge_error_reasons(error_reasons)
      |> Map.update!(:tick_lags_ms, &[tick.lag_ms | &1])
      |> Map.update!(:tick_due_counts, &[tick.due_count | &1])
      |> Map.update!(:tick_send_counts, &[actual_send_count | &1])
      |> maybe_record_burst(actual_send_count, duration_us)
      |> Map.put(:stop_reason, stop_reason)

    {%{tick | send_count: actual_send_count, stop_reason: stop_reason}, state}
  end

  defp pop_many(queue, count), do: pop_many(queue, count, [])

  defp pop_many(queue, 0, payloads), do: {Enum.reverse(payloads), queue}

  defp pop_many(queue, count, payloads) do
    case :queue.out(queue) do
      {{:value, payload}, queue} ->
        pop_many(queue, count - 1, [payload | payloads])

      {:empty, queue} ->
        {Enum.reverse(payloads), queue}
    end
  end

  defp send_payloads([], _send_fun, transport_state, _stop_on_error?) do
    {0, 0, %{}, transport_state, 0, false}
  end

  defp send_payloads(payloads, send_fun, transport_state, stop_on_error?) do
    started_at = monotonic_us()

    {accepted, errors, error_reasons, transport_state, stopped_on_error?} =
      Enum.reduce_while(payloads, {0, 0, %{}, transport_state, false}, fn payload,
                                                                          {accepted, errors,
                                                                           reasons,
                                                                           transport_state,
                                                                           _stopped?} ->
        case send_fun.(payload, transport_state) do
          :ok ->
            {:cont, {accepted + 1, errors, reasons, transport_state, false}}

          {:ok, transport_state} ->
            {:cont, {accepted + 1, errors, reasons, transport_state, false}}

          {:error, reason} ->
            reasons = increment_error_reason(reasons, reason)
            maybe_stop_on_error(accepted, errors + 1, reasons, transport_state, stop_on_error?)

          {:error, reason, transport_state} ->
            reasons = increment_error_reason(reasons, reason)
            maybe_stop_on_error(accepted, errors + 1, reasons, transport_state, stop_on_error?)
        end
      end)

    {accepted, errors, error_reasons, transport_state, monotonic_us() - started_at,
     stopped_on_error?}
  end

  defp maybe_stop_on_error(accepted, errors, reasons, transport_state, false) do
    {:cont, {accepted, errors, reasons, transport_state, false}}
  end

  defp maybe_stop_on_error(accepted, errors, reasons, transport_state, true) do
    {:halt, {accepted, errors, reasons, transport_state, true}}
  end

  defp stop_reason(_tick, _actual_send_count, true), do: :send_error
  defp stop_reason(%{tool_limited?: true}, _actual_send_count, _stopped?), do: :tool_limited
  defp stop_reason(%{stop_reason: :complete}, _actual_send_count, _stopped?), do: :complete

  defp stop_reason(%{send_count: expected}, actual, _stopped?) when actual < expected,
    do: :producer_limited

  defp stop_reason(_tick, _actual_send_count, _stopped?), do: nil

  defp restore_unsent_payloads(queue, payloads, actual_send_count) do
    payloads
    |> Enum.drop(actual_send_count)
    |> Enum.reverse()
    |> Enum.reduce(queue, fn payload, queue -> :queue.in_r(payload, queue) end)
  end

  defp maybe_record_burst(state, 0, _duration_us), do: state

  defp maybe_record_burst(state, count, duration_us) do
    state
    |> Map.update!(:burst_counts, &[count | &1])
    |> Map.update!(:burst_durations_us, &[duration_us | &1])
  end

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
      errors: state.errors,
      error_reasons: state.error_reasons,
      queue_depth: :queue.len(state.queue),
      stop_reason: state.stop_reason,
      transport_state: state.transport_state,
      pacer: state.pacer,
      burst_counts: Enum.reverse(state.burst_counts),
      burst_durations_us: Enum.reverse(state.burst_durations_us),
      tick_lags_ms: Enum.reverse(state.tick_lags_ms),
      tick_due_counts: Enum.reverse(state.tick_due_counts),
      tick_send_counts: Enum.reverse(state.tick_send_counts)
    }
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp schedule_tick(ref, deadline_ms) do
    Process.send_after(self(), {:traffic_datagram_sink_tick, ref}, deadline_ms, abs: true)
    :ok
  end
end
