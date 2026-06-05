defmodule MOQXProbe.Traffic.StreamSender do
  @moduledoc false

  alias MOQXProbe.Traffic
  alias MOQXProbe.Traffic.Pacer
  alias MOQXProbe.Traffic.StreamSink

  @telemetry_prefix [:moqx, :transport_bench, :stream_sender]
  @tick_ms 1

  defstruct [
    :sink,
    :producer,
    :count,
    :payload_timeout,
    :started_at_ms,
    :idle_sleep_ms,
    :idle_retries
  ]

  def start(opts) when is_list(opts) do
    count = Keyword.fetch!(opts, :count)
    started_at_us = Keyword.fetch!(opts, :started_at_us)
    started_at_ms = System.convert_time_unit(started_at_us, :microsecond, :millisecond)
    max_burst = Keyword.get(opts, :max_burst, default_max_burst(count))
    max_queue_depth = Keyword.get(opts, :max_queue_depth, default_max_queue_depth(max_burst))
    events = Keyword.get(opts, :events) || events_for(opts)

    emit_run_start(count, max_burst, max_queue_depth)

    with {:ok, sink} <- start_sink(opts, count, started_at_ms, max_burst, max_queue_depth),
         {:ok, producer} <-
           Traffic.start_payloads(events, sink,
             mapper: Keyword.get(opts, :mapper, & &1),
             stages: Keyword.get(opts, :stages, 1),
             min_demand: Keyword.get(opts, :min_demand, default_min_demand(max_burst)),
             max_demand: Keyword.get(opts, :max_demand, max_burst)
           ) do
      {:ok,
       %__MODULE__{
         sink: sink,
         producer: producer,
         count: count,
         payload_timeout: Keyword.get(opts, :payload_timeout, 5_000),
         started_at_ms: started_at_ms,
         idle_sleep_ms: Keyword.get(opts, :idle_sleep_ms, 1),
         idle_retries: Keyword.get(opts, :idle_retries, 20)
       }}
    end
  end

  def run(opts) when is_list(opts) do
    with {:ok, sender} <- start(opts),
         {:ok, _snapshot} <- drain(sender) do
      finish(sender)
    end
  end

  def run(%__MODULE__{} = sender) do
    with {:ok, _snapshot} <- drain(sender) do
      finish(sender)
    end
  end

  def drain(%__MODULE__{} = sender) do
    drain(sender, sender.idle_retries)
  end

  def complete(%__MODULE__{} = sender, stream, count \\ 1)
      when is_integer(count) and count >= 0 do
    :ok = StreamSink.complete(sender.sink, stream, count)
    drain(sender)
  end

  def snapshot(%__MODULE__{} = sender) do
    StreamSink.snapshot(sender.sink)
  end

  def update_transport_state(%__MODULE__{} = sender, fun) when is_function(fun, 1) do
    :ok = StreamSink.update_transport_state(sender.sink, fun)
    sender
  end

  def finish(%__MODULE__{} = sender) do
    snapshot = snapshot(sender)
    producer_result = finish_payload_producer(snapshot.stop_reason, sender)

    snapshot =
      sender.sink
      |> StreamSink.snapshot()
      |> Map.put(:payload_producer_result, producer_result)

    stop_sink(sender.sink)

    result =
      case producer_result do
        :ok -> {:ok, snapshot}
        {:error, reason} -> {:error, reason, snapshot}
      end

    emit_run_stop(result)
    result
  end

  def stop(%__MODULE__{} = sender) do
    Traffic.stop_payloads(sender.producer)
    snapshot = StreamSink.snapshot(sender.sink)
    stop_sink(sender.sink)
    result = {:ok, Map.put(snapshot, :payload_producer_result, :stopped)}
    emit_run_stop(result)
    result
  end

  def events_for(opts) do
    streams = Keyword.fetch!(opts, :streams)
    payload = Keyword.fetch!(opts, :payload)
    payload_count = Keyword.fetch!(opts, :payload_count)

    1..payload_count
    |> Elixir.Stream.flat_map(fn payload_index ->
      Enum.map(streams, fn stream ->
        %{
          stream: stream.stream,
          stream_index: stream.index,
          payload: payload,
          payload_index: payload_index,
          finish?: payload_index == payload_count
        }
      end)
    end)
  end

  def default_max_burst(count) when is_integer(count) and count > 0 do
    min(count, 64)
  end

  def default_min_demand(max_burst) when is_integer(max_burst) and max_burst > 0 do
    max(max_burst - 1, 0)
  end

  def default_max_queue_depth(max_burst) when is_integer(max_burst) and max_burst > 0 do
    max(max_burst * 4, 64)
  end

  defp start_sink(opts, count, started_at_ms, max_burst, max_queue_depth) do
    rate = Keyword.get(opts, :rate_per_second, count * 1_000)

    StreamSink.start_link(
      pacer:
        Pacer.new!(
          count: count,
          rate_per_second: rate,
          tick_ms: @tick_ms,
          max_burst: max_burst,
          started_at_ms: started_at_ms
        ),
      send_fun: Keyword.fetch!(opts, :send_fun),
      complete_fun: Keyword.get(opts, :complete_fun, &default_complete_fun/3),
      transport_state: Keyword.get(opts, :transport_state),
      event_forward_pid: Keyword.get(opts, :event_forward_pid),
      stream_send_window: Keyword.fetch!(opts, :stream_send_window),
      max_queue_depth: max_queue_depth,
      now_fun: Keyword.get(opts, :now_fun, &monotonic_ms/0),
      timer_fun: Keyword.get(opts, :timer_fun, &schedule_tick/2)
    )
  end

  defp drain(sender, retries_left) do
    tick = StreamSink.tick(sender.sink, pressure_now_ms(sender))
    snapshot = StreamSink.snapshot(sender.sink)

    cond do
      snapshot.stop_reason ->
        {:ok, snapshot}

      tick.send_count > 0 ->
        drain(sender, sender.idle_retries)

      queued_after_empty_tick?(tick, snapshot) and retries_left > 0 ->
        drain(sender, retries_left - 1)

      pending_producer_payloads?(snapshot) and retries_left > 0 ->
        Process.sleep(sender.idle_sleep_ms)
        drain(sender, retries_left - 1)

      true ->
        {:ok, snapshot}
    end
  end

  defp pressure_now_ms(sender) do
    max(monotonic_ms(), sender.started_at_ms + 1)
  end

  defp pending_producer_payloads?(snapshot) do
    snapshot.queue_depth == 0 and snapshot.accepted + snapshot.errors < snapshot.pacer.count
  end

  defp queued_after_empty_tick?(tick, snapshot) do
    snapshot.queue_depth > 0 and tick.send_count == 0 and not tick.stream_window_limited?
  end

  defp finish_payload_producer(:complete, sender) do
    case Traffic.await_payloads(sender.producer, sender.payload_timeout) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        Traffic.stop_payloads(sender.producer)
        error
    end
  end

  defp finish_payload_producer(_stop_reason, sender) do
    Traffic.stop_payloads(sender.producer)
  end

  defp stop_sink(sink) do
    if Process.alive?(sink) do
      Process.unlink(sink)
      GenStage.stop(sink, :normal, 1_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp default_complete_fun(_stream, _count, transport_state), do: transport_state

  defp emit_run_start(count, max_burst, max_queue_depth) do
    :telemetry.execute(
      @telemetry_prefix ++ [:run, :start],
      %{count: count, max_burst: max_burst, max_queue_depth: max_queue_depth},
      %{sender: :stream}
    )
  end

  defp emit_run_stop({:ok, snapshot}) do
    :telemetry.execute(
      @telemetry_prefix ++ [:run, :stop],
      run_stop_measurements(snapshot),
      %{sender: :stream, result: :ok, stop_reason: snapshot.stop_reason}
    )
  end

  defp emit_run_stop({:error, reason, snapshot}) do
    :telemetry.execute(
      @telemetry_prefix ++ [:run, :stop],
      run_stop_measurements(snapshot),
      %{sender: :stream, result: :error, reason: reason, stop_reason: snapshot.stop_reason}
    )
  end

  defp run_stop_measurements(snapshot) do
    %{
      accepted_count: snapshot.accepted,
      completed_count: snapshot.completed,
      error_count: snapshot.errors,
      queue_depth: snapshot.queue_depth,
      outstanding_demand: snapshot.outstanding_demand,
      in_flight: snapshot.in_flight,
      max_queue_depth: telemetry_queue_depth(snapshot.max_queue_depth)
    }
  end

  defp telemetry_queue_depth(:infinity), do: -1
  defp telemetry_queue_depth(max_queue_depth), do: max_queue_depth

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp schedule_tick(ref, deadline_ms) do
    Process.send_after(self(), {:traffic_stream_sink_tick, ref}, deadline_ms, abs: true)
    :ok
  end
end
