defmodule MOQXProbe.Traffic.DatagramSender do
  @moduledoc false

  alias MOQXProbe.DatagramPayload
  alias MOQXProbe.Traffic
  alias MOQXProbe.Traffic.DatagramSink
  alias MOQXProbe.Traffic.Pacer

  @telemetry_prefix [:moqx, :transport_bench, :datagram_sender]
  @tick_ms 1

  def run(opts) when is_list(opts) do
    count = Keyword.fetch!(opts, :count)
    rate = Keyword.fetch!(opts, :rate_per_second)
    started_at_us = Keyword.fetch!(opts, :started_at_us)
    timeout = Keyword.get(opts, :timeout, :infinity)
    payload_timeout = Keyword.get(opts, :payload_timeout, 5_000)
    max_burst = Keyword.get(opts, :max_burst, default_max_burst(rate))
    max_queue_depth = Keyword.get(opts, :max_queue_depth, default_max_queue_depth(max_burst))
    payload_mapper = Keyword.get(opts, :mapper) || payload_mapper(opts)

    emit_run_start(count, rate, max_burst, max_queue_depth)

    result =
      with {:ok, sink} <- start_sink(opts, count, rate, started_at_us, max_burst, max_queue_depth),
           {:ok, producer} <-
             Traffic.start_payloads(1..count, sink,
               mapper: payload_mapper,
               stages: Keyword.get(opts, :stages, 1),
               min_demand: Keyword.get(opts, :min_demand, default_min_demand(max_burst)),
               max_demand: Keyword.get(opts, :max_demand, max_burst)
             ) do
        snapshot = DatagramSink.run(sink, timeout)
        producer_result = finish_payload_producer(snapshot.stop_reason, producer, payload_timeout)

        snapshot =
          sink
          |> DatagramSink.snapshot()
          |> Map.put(:payload_producer_result, producer_result)

        case producer_result do
          :ok -> {:ok, snapshot}
          {:error, reason} -> {:error, reason, snapshot}
        end
      end

    emit_run_stop(result)
    result
  end

  def default_max_burst(rate) when is_integer(rate) and rate > 0 do
    max(1, div(rate + 999, 1_000))
  end

  def default_min_demand(max_burst) when is_integer(max_burst) and max_burst > 0 do
    max(max_burst - 1, 0)
  end

  def default_max_queue_depth(max_burst) when is_integer(max_burst) and max_burst > 0 do
    max(max_burst * 4, 64)
  end

  defp start_sink(opts, count, rate, started_at_us, max_burst, max_queue_depth) do
    pacer_opts =
      [
        count: count,
        rate_per_second: rate,
        tick_ms: @tick_ms,
        max_burst: max_burst,
        started_at_ms: System.convert_time_unit(started_at_us, :microsecond, :millisecond)
      ]
      |> maybe_put_max_lag(Keyword.get(opts, :max_lag_ms))

    DatagramSink.start_link(
      pacer: Pacer.new!(pacer_opts),
      send_fun: Keyword.fetch!(opts, :send_fun),
      transport_state: Keyword.get(opts, :transport_state),
      stop_on_error?: Keyword.get(opts, :stop_on_error?, false),
      max_queue_depth: max_queue_depth,
      now_fun: Keyword.get(opts, :now_fun, &monotonic_ms/0),
      timer_fun: Keyword.get(opts, :timer_fun, &schedule_tick/2)
    )
  end

  defp maybe_put_max_lag(pacer_opts, nil), do: pacer_opts

  defp maybe_put_max_lag(pacer_opts, max_lag_ms),
    do: Keyword.put(pacer_opts, :max_lag_ms, max_lag_ms)

  defp payload_mapper(opts) do
    case Keyword.fetch!(opts, :payload_mode) do
      {:sequence_timestamp, datagram_size} ->
        payload_padding = DatagramPayload.padding_for_size(datagram_size)
        fn sequence -> %{sequence: sequence, padding: payload_padding} end

      {:fixed, payload} when is_binary(payload) ->
        fn _sequence -> payload end

      {:prefilled_ring, payloads} when is_list(payloads) and payloads != [] ->
        payload_count = length(payloads)
        fn sequence -> Enum.at(payloads, rem(sequence - 1, payload_count)) end
    end
  end

  defp finish_payload_producer(:complete, producer, timeout) do
    case Traffic.await_payloads(producer, timeout) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        Traffic.stop_payloads(producer)
        error
    end
  end

  defp finish_payload_producer(_stop_reason, producer, _timeout) do
    Traffic.stop_payloads(producer)
  end

  defp emit_run_start(count, rate, max_burst, max_queue_depth) do
    :telemetry.execute(
      @telemetry_prefix ++ [:run, :start],
      %{
        count: count,
        rate_per_second: rate,
        max_burst: max_burst,
        max_queue_depth: max_queue_depth
      },
      %{sender: :datagram}
    )
  end

  defp emit_run_stop({:ok, snapshot}) do
    :telemetry.execute(
      @telemetry_prefix ++ [:run, :stop],
      run_stop_measurements(snapshot),
      %{sender: :datagram, result: :ok, stop_reason: snapshot.stop_reason}
    )
  end

  defp emit_run_stop({:error, reason, snapshot}) do
    :telemetry.execute(
      @telemetry_prefix ++ [:run, :stop],
      run_stop_measurements(snapshot),
      %{sender: :datagram, result: :error, reason: reason, stop_reason: snapshot.stop_reason}
    )
  end

  defp emit_run_stop({:error, reason}) do
    :telemetry.execute(
      @telemetry_prefix ++ [:run, :stop],
      %{},
      %{sender: :datagram, result: :error, reason: reason}
    )
  end

  defp run_stop_measurements(snapshot) do
    %{
      accepted_count: snapshot.accepted,
      error_count: snapshot.errors,
      queue_depth: snapshot.queue_depth,
      outstanding_demand: snapshot.outstanding_demand,
      max_queue_depth: telemetry_queue_depth(snapshot.max_queue_depth)
    }
  end

  defp telemetry_queue_depth(:infinity), do: -1
  defp telemetry_queue_depth(max_queue_depth), do: max_queue_depth

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp schedule_tick(ref, deadline_ms) do
    Process.send_after(self(), {:traffic_datagram_sink_tick, ref}, deadline_ms, abs: true)
    :ok
  end
end
