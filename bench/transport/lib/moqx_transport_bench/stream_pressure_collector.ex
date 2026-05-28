defmodule MOQX.TransportBench.StreamPressureCollector do
  @moduledoc false

  @events [
    [:moqx, :transport, :stream, :send, :stop],
    [:moqx, :transport, :event, :receive, :stop]
  ]

  @message_queue_sample_prefix_count 16
  @message_queue_sample_stride 1_024
  @sample_interval_ms 10

  defstruct [:handler_id, :owner_pid, :sampler_pid, :sampler_ref, :table]

  def start(opts \\ []) do
    with {:ok, _apps} <- Application.ensure_all_started(:telemetry) do
      start_collector(opts)
    end
  end

  defp start_collector(opts) do
    owner_pid = Keyword.get(opts, :owner_pid, self())
    handler_id = {__MODULE__, owner_pid, make_ref()}

    table =
      :ets.new(__MODULE__, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    started_at_us = monotonic_us()
    :ets.insert(table, {:started_at_us, started_at_us})

    {sampler_pid, sampler_ref} =
      maybe_start_sampler(
        table,
        owner_pid,
        started_at_us,
        Keyword.get(opts, :sample_process?, false)
      )

    collector = %__MODULE__{
      handler_id: handler_id,
      owner_pid: owner_pid,
      sampler_pid: sampler_pid,
      sampler_ref: sampler_ref,
      table: table
    }

    case :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, %{
           owner_pid: owner_pid,
           table: table
         }) do
      :ok ->
        {:ok, collector}

      {:error, reason} ->
        close(collector)
        {:error, reason}
    end
  end

  def snapshot(%__MODULE__{table: table}) do
    %{
      send_stream_call_durations_us: duration_values(table, :stream_send_call),
      stream_send_bytes_accepted: counter(table, {:stream_send, :bytes_accepted}),
      stream_send_accepted: counter(table, {:stream_send, :accepted}),
      stream_send_errors: counter(table, {:stream_send, :errors}),
      runtime_diagnostics: %{
        process: process_samples(table),
        events_drained: counter(table, {:receive_event, :events_drained}),
        stream_data_events: counter(table, {:receive_event, :stream_data}),
        stream_data_bytes_received: counter(table, {:receive_event, :stream_data_bytes}),
        send_completed_events: counter(table, {:receive_event, {:stream_event, :send_completed}}),
        send_cancelled_events: counter(table, {:receive_event, {:stream_event, :send_cancelled}}),
        peer_finished_events:
          counter(table, {:receive_event, {:stream_event, :peer_finished_sending}}),
        stream_closed_events: counter(table, {:receive_event, {:stream_event, :closed}}),
        ignored_events: counter(table, {:receive_event, :ignored}),
        unknown_events: counter(table, {:receive_event, :unknown}),
        receive_errors: counter(table, {:receive_event, :errors}),
        timeouts: counter(table, {:receive_event, :timeouts}),
        receive_event_call_durations_us: duration_values(table, :receive_event_call),
        receive_event_blocking_call_durations_us:
          duration_values(table, :receive_event_blocking_call),
        receive_event_drain_call_durations_us: duration_values(table, :receive_event_drain_call)
      }
    }
  end

  def close(%__MODULE__{} = collector) do
    :telemetry.detach(collector.handler_id)
    stop_sampler(collector)
    :ets.delete(collector.table)
    :ok
  end

  def handle_event(event, measurements, metadata, %{owner_pid: owner_pid, table: table}) do
    if self() == owner_pid do
      do_handle_event(event, measurements, metadata, table)
    end
  end

  defp do_handle_event([:moqx, :transport, :stream, :send, :stop], measurements, metadata, table) do
    add_duration(table, :stream_send_call, measurements[:duration_us])

    case metadata[:result] do
      :ok ->
        increment(table, {:stream_send, :accepted})
        increment(table, {:stream_send, :bytes_accepted}, measurements[:byte_size] || 0)

      :error ->
        increment(table, {:stream_send, :errors})

      _other ->
        :ok
    end
  end

  defp do_handle_event(
         [:moqx, :transport, :event, :receive, :stop],
         measurements,
         metadata,
         table
       ) do
    add_duration(table, :receive_event_call, measurements[:duration_us])

    if measurements[:timeout_ms] == 0 do
      add_duration(table, :receive_event_drain_call, measurements[:duration_us])
    else
      add_duration(table, :receive_event_blocking_call, measurements[:duration_us])
    end

    record_receive_result(table, measurements, metadata)
  end

  defp record_receive_result(
         table,
         measurements,
         %{result: :ok, event_kind: event_kind} = metadata
       ) do
    increment(table, {:receive_event, :events_drained})

    case {event_kind, metadata[:event_name]} do
      {:stream_data, _event_name} ->
        increment(table, {:receive_event, :stream_data})
        increment(table, {:receive_event, :stream_data_bytes}, measurements[:byte_size] || 0)

      {:stream_event, event_name}
      when event_name in [:send_completed, :send_cancelled, :peer_finished_sending, :closed] ->
        increment(table, {:receive_event, {:stream_event, event_name}})

      _other ->
        increment(table, {:receive_event, :ignored})
    end
  end

  defp record_receive_result(table, _measurements, %{result: :timeout}) do
    increment(table, {:receive_event, :timeouts})
  end

  defp record_receive_result(table, _measurements, %{result: :unknown}) do
    increment(table, {:receive_event, :unknown})
  end

  defp record_receive_result(table, _measurements, %{result: :error}) do
    increment(table, {:receive_event, :errors})
  end

  defp record_receive_result(_table, _measurements, _metadata), do: :ok

  defp add_duration(_table, _key, nil), do: :ok

  defp add_duration(table, key, duration_us) do
    index =
      :ets.update_counter(table, {:duration_index, key}, {2, 1}, {{:duration_index, key}, 0})

    :ets.insert(table, {{:duration, key, index}, duration_us})
  end

  defp duration_values(table, key) do
    table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:duration, ^key, index}, value} -> [{index, value}]
      _entry -> []
    end)
    |> Enum.sort_by(fn {index, _value} -> index end)
    |> Enum.map(fn {_index, value} -> value end)
  end

  defp increment(table, key, amount \\ 1) do
    :ets.update_counter(table, {:counter, key}, {2, amount}, {{:counter, key}, 0})
    :ok
  end

  defp counter(table, key) do
    case :ets.lookup(table, {:counter, key}) do
      [{{:counter, ^key}, value}] -> value
      [] -> 0
    end
  end

  defp maybe_start_sampler(_table, _owner_pid, _started_at_us, false), do: {nil, nil}

  defp maybe_start_sampler(table, owner_pid, started_at_us, true) do
    ref = make_ref()

    pid =
      spawn_link(fn ->
        sampler_loop(table, owner_pid, started_at_us, ref)
      end)

    {pid, ref}
  end

  defp sampler_loop(table, owner_pid, started_at_us, ref) do
    sample_process(table, owner_pid, started_at_us)

    receive do
      {:stop_sampler, ^ref} -> :ok
    after
      @sample_interval_ms -> sampler_loop(table, owner_pid, started_at_us, ref)
    end
  end

  defp stop_sampler(%__MODULE__{sampler_pid: nil}), do: :ok

  defp stop_sampler(%__MODULE__{sampler_pid: pid, sampler_ref: ref}) do
    send(pid, {:stop_sampler, ref})
    :ok
  end

  defp sample_process(table, owner_pid, started_at_us) do
    message_queue_len = message_queue_len(owner_pid)
    sample_index = increment_sample_count(table)
    update_message_queue_peak(table, message_queue_len)

    if keep_message_queue_sample?(sample_index) do
      :ets.insert(table, {
        {:message_queue_sample, sample_index},
        %{
          "sample_index" => sample_index,
          "elapsed_ms" => (monotonic_us() - started_at_us) / 1000,
          "message_queue_len" => message_queue_len
        }
      })
    end
  end

  defp increment_sample_count(table) do
    :ets.update_counter(
      table,
      :message_queue_len_samples,
      {2, 1},
      {:message_queue_len_samples, 0}
    )
  end

  defp update_message_queue_peak(table, message_queue_len) do
    peak =
      case :ets.lookup(table, :message_queue_len_peak) do
        [{:message_queue_len_peak, value}] -> max(value, message_queue_len)
        [] -> message_queue_len
      end

    :ets.insert(table, {:message_queue_len_peak, peak})
  end

  defp process_samples(table) do
    sample_count = scalar(table, :message_queue_len_samples, 0)
    sample_points = message_queue_sample_points(table)
    peak = scalar(table, :message_queue_len_peak)

    if sample_count == 0 and peak == nil and sample_points == [] do
      %{}
    else
      %{
        "message_queue_len_peak" => peak,
        "message_queue_len_samples" => sample_count,
        "message_queue_len_sample_points" => sample_points
      }
    end
  end

  defp message_queue_sample_points(table) do
    table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:message_queue_sample, index}, point} -> [{index, point}]
      _entry -> []
    end)
    |> Enum.sort_by(fn {index, _point} -> index end)
    |> Enum.map(fn {_index, point} -> point end)
  end

  defp scalar(table, key, default \\ nil) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp keep_message_queue_sample?(sample_index) do
    sample_index <= @message_queue_sample_prefix_count or
      rem(sample_index, @message_queue_sample_stride) == 0
  end

  defp message_queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, value} -> value
      nil -> 0
    end
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
end
