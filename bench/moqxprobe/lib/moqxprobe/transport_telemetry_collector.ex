defmodule MOQXProbe.TransportTelemetryCollector do
  @moduledoc false

  @events [
    [:moqx, :transport, :stream, :send, :stop],
    [:moqx, :transport, :stream, :recv, :stop],
    [:moqx, :transport, :datagram, :send, :stop],
    [:moqx, :transport, :event, :receive, :stop],
    [:moqx, :transport_bench, :datagram_sender, :run, :start],
    [:moqx, :transport_bench, :datagram_sender, :run, :stop],
    [:moqx, :transport_bench, :datagram_sender, :demand, :ask],
    [:moqx, :transport_bench, :datagram_sender, :backlog, :change],
    [:moqx, :transport_bench, :datagram_sender, :tick, :stop],
    [:moqx, :transport_bench, :datagram_sender, :send, :error]
  ]

  @message_queue_sample_prefix_count 16
  @message_queue_sample_stride 1_024
  @sample_interval_ms 10
  @duration_keys [
    :stream_send_call,
    :stream_recv_call,
    :datagram_send_call,
    :receive_event_call,
    :receive_event_blocking_call,
    :receive_event_drain_call,
    :datagram_sender_burst
  ]
  @counter_keys [
    {:stream_send, :bytes_accepted},
    {:stream_send, :accepted},
    {:stream_send, :errors},
    {:stream_recv, :bytes},
    {:stream_recv, :ok},
    {:stream_recv, :errors},
    {:datagram_send, :bytes_accepted},
    {:datagram_send, :accepted},
    {:datagram_send, :errors},
    {:receive_event, :events_drained},
    {:receive_event, :stream_data},
    {:receive_event, :stream_data_bytes},
    {:receive_event, :datagram},
    {:receive_event, :datagram_bytes},
    {:receive_event, {:stream_event, :send_completed}},
    {:receive_event, {:stream_event, :send_cancelled}},
    {:receive_event, {:stream_event, :peer_finished_sending}},
    {:receive_event, {:stream_event, :closed}},
    {:receive_event, :ignored},
    {:receive_event, :unknown},
    {:receive_event, :errors},
    {:receive_event, :timeouts},
    {:datagram_sender, :runs_started},
    {:datagram_sender, :runs_stopped},
    {:datagram_sender, :runs_failed},
    {:datagram_sender, :demand_asked},
    {:datagram_sender, :payloads_enqueued},
    {:datagram_sender, :ticks},
    {:datagram_sender, :due},
    {:datagram_sender, :sent},
    {:datagram_sender, :accepted},
    {:datagram_sender, :errors},
    {:datagram_sender, :send_error_events},
    {:datagram_sender, :capped_ticks},
    {:datagram_sender, :tool_limited_ticks}
  ]

  defstruct [
    :attached?,
    :handler_id,
    :owner_pid,
    :sampler_pid,
    :sampler_ref,
    :sampler_monitor_ref,
    :store_key,
    :table
  ]

  def start(opts \\ []) do
    with {:ok, _apps} <- Application.ensure_all_started(:telemetry) do
      start_collector(opts)
    end
  end

  defp start_collector(opts) do
    owner_pid = Keyword.get(opts, :owner_pid, self())
    event_owner_pid = Keyword.get(opts, :event_owner_pid, owner_pid)

    table =
      :ets.new(__MODULE__, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    handler_id = {__MODULE__, owner_pid, make_ref()}
    store_key = {__MODULE__, handler_id}
    init_owner_store(store_key)

    started_at_us = monotonic_us()
    :ets.insert(table, {:started_at_us, started_at_us})

    {sampler_pid, sampler_ref, sampler_monitor_ref} =
      maybe_start_sampler(
        table,
        owner_pid,
        started_at_us,
        Keyword.get(opts, :sample_process?, false)
      )

    collector = %__MODULE__{
      attached?: false,
      handler_id: handler_id,
      owner_pid: owner_pid,
      sampler_pid: sampler_pid,
      sampler_ref: sampler_ref,
      sampler_monitor_ref: sampler_monitor_ref,
      store_key: store_key,
      table: table
    }

    events =
      case Keyword.get(opts, :events, @events) do
        nil -> @events
        :default -> @events
        events -> events
      end

    if events == [] do
      {:ok, collector}
    else
      case :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, %{
             event_owner_pid: event_owner_pid,
             store: %{key: store_key, table: table},
             table: table
           }) do
        :ok ->
          {:ok, %{collector | attached?: true}}

        {:error, reason} ->
          close(collector)
          {:error, reason}
      end
    end
  end

  def snapshot(%__MODULE__{} = collector) do
    %{
      send_stream_call_durations_us: duration_values(collector, :stream_send_call),
      stream_send_bytes_accepted: counter(collector, {:stream_send, :bytes_accepted}),
      stream_send_accepted: counter(collector, {:stream_send, :accepted}),
      stream_send_errors: counter(collector, {:stream_send, :errors}),
      recv_stream_call_durations_us: duration_values(collector, :stream_recv_call),
      stream_recv_bytes: counter(collector, {:stream_recv, :bytes}),
      stream_recv_ok: counter(collector, {:stream_recv, :ok}),
      stream_recv_errors: counter(collector, {:stream_recv, :errors}),
      send_datagram_call_durations_us: duration_values(collector, :datagram_send_call),
      datagram_send_bytes_accepted: counter(collector, {:datagram_send, :bytes_accepted}),
      datagram_send_accepted: counter(collector, {:datagram_send, :accepted}),
      datagram_send_errors: counter(collector, {:datagram_send, :errors}),
      runtime_diagnostics: %{
        process: process_samples(collector.table),
        events_drained: counter(collector, {:receive_event, :events_drained}),
        stream_data_events: counter(collector, {:receive_event, :stream_data}),
        stream_data_bytes_received: counter(collector, {:receive_event, :stream_data_bytes}),
        datagram_events: counter(collector, {:receive_event, :datagram}),
        datagram_bytes_received: counter(collector, {:receive_event, :datagram_bytes}),
        send_completed_events:
          counter(collector, {:receive_event, {:stream_event, :send_completed}}),
        send_cancelled_events:
          counter(collector, {:receive_event, {:stream_event, :send_cancelled}}),
        peer_finished_events:
          counter(collector, {:receive_event, {:stream_event, :peer_finished_sending}}),
        stream_closed_events: counter(collector, {:receive_event, {:stream_event, :closed}}),
        ignored_events: counter(collector, {:receive_event, :ignored}),
        unknown_events: counter(collector, {:receive_event, :unknown}),
        receive_errors: counter(collector, {:receive_event, :errors}),
        timeouts: counter(collector, {:receive_event, :timeouts}),
        receive_event_call_durations_us: duration_values(collector, :receive_event_call),
        receive_event_blocking_call_durations_us:
          duration_values(collector, :receive_event_blocking_call),
        receive_event_drain_call_durations_us:
          duration_values(collector, :receive_event_drain_call),
        datagram_sender: datagram_sender_snapshot(collector)
      }
    }
  end

  def close(%__MODULE__{} = collector) do
    if collector.attached? do
      :telemetry.detach(collector.handler_id)
    end

    stop_sampler(collector)
    :ets.delete(collector.table)
    clear_owner_store(collector.store_key)
    :ok
  end

  def handle_event(event, measurements, metadata, %{
        event_owner_pid: :any,
        store: store
      }) do
    do_handle_event(event, measurements, metadata, store)
  end

  def handle_event(event, measurements, metadata, %{
        event_owner_pid: owner_pid,
        store: store
      }) do
    if self() == owner_pid do
      do_handle_event(event, measurements, metadata, store)
    end
  end

  defp do_handle_event(
         [:moqx, :transport, :stream, :recv, :stop],
         measurements,
         metadata,
         store_key
       ) do
    add_duration(store_key, :stream_recv_call, measurements[:duration_us])

    case metadata[:result] do
      :ok ->
        increment(store_key, {:stream_recv, :ok})
        increment(store_key, {:stream_recv, :bytes}, measurements[:byte_size] || 0)

      :error ->
        increment(store_key, {:stream_recv, :errors})

      _other ->
        :ok
    end
  end

  defp do_handle_event(
         [:moqx, :transport, :datagram, :send, :stop],
         measurements,
         metadata,
         store_key
       ) do
    add_duration(store_key, :datagram_send_call, measurements[:duration_us])

    case metadata[:result] do
      :ok ->
        increment(store_key, {:datagram_send, :accepted})
        increment(store_key, {:datagram_send, :bytes_accepted}, measurements[:byte_size] || 0)

      :error ->
        increment(store_key, {:datagram_send, :errors})

      _other ->
        :ok
    end
  end

  defp do_handle_event(
         [:moqx, :transport, :stream, :send, :stop],
         measurements,
         metadata,
         store_key
       ) do
    add_duration(store_key, :stream_send_call, measurements[:duration_us])

    case metadata[:result] do
      :ok ->
        increment(store_key, {:stream_send, :accepted})
        increment(store_key, {:stream_send, :bytes_accepted}, measurements[:byte_size] || 0)

      :error ->
        increment(store_key, {:stream_send, :errors})

      _other ->
        :ok
    end
  end

  defp do_handle_event(
         [:moqx, :transport, :event, :receive, :stop],
         measurements,
         metadata,
         store_key
       ) do
    add_duration(store_key, :receive_event_call, measurements[:duration_us])

    if measurements[:timeout_ms] == 0 do
      add_duration(store_key, :receive_event_drain_call, measurements[:duration_us])
    else
      add_duration(store_key, :receive_event_blocking_call, measurements[:duration_us])
    end

    record_receive_result(store_key, measurements, metadata)
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :datagram_sender, :run, :start],
         _measurements,
         _metadata,
         store_key
       ) do
    increment(store_key, {:datagram_sender, :runs_started})
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :datagram_sender, :run, :stop],
         _measurements,
         metadata,
         store_key
       ) do
    increment(store_key, {:datagram_sender, :runs_stopped})

    if metadata[:result] == :error do
      increment(store_key, {:datagram_sender, :runs_failed})
    end
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :datagram_sender, :demand, :ask],
         measurements,
         _metadata,
         store_key
       ) do
    increment(store_key, {:datagram_sender, :demand_asked}, measurements[:demand_count] || 0)
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :datagram_sender, :backlog, :change],
         measurements,
         _metadata,
         store_key
       ) do
    increment(
      store_key,
      {:datagram_sender, :payloads_enqueued},
      measurements[:enqueued_count] || 0
    )
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :datagram_sender, :tick, :stop],
         measurements,
         _metadata,
         store_key
       ) do
    increment(store_key, {:datagram_sender, :ticks})
    increment(store_key, {:datagram_sender, :due}, measurements[:due_count] || 0)
    increment(store_key, {:datagram_sender, :sent}, measurements[:send_count] || 0)
    increment(store_key, {:datagram_sender, :accepted}, measurements[:accepted_count] || 0)
    increment(store_key, {:datagram_sender, :errors}, measurements[:error_count] || 0)
    increment(store_key, {:datagram_sender, :capped_ticks}, measurements[:capped_tick_count] || 0)

    increment(
      store_key,
      {:datagram_sender, :tool_limited_ticks},
      measurements[:tool_limited_tick_count] || 0
    )

    add_duration(store_key, :datagram_sender_burst, measurements[:burst_duration_us])
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :datagram_sender, :send, :error],
         measurements,
         _metadata,
         store_key
       ) do
    increment(store_key, {:datagram_sender, :send_error_events}, measurements[:error_count] || 0)
  end

  defp do_handle_event(_event, _measurements, _metadata, _store_key), do: :ok

  defp record_receive_result(
         store_key,
         measurements,
         %{result: :ok, event_kind: event_kind} = metadata
       ) do
    increment(store_key, {:receive_event, :events_drained})

    case {event_kind, metadata[:event_name]} do
      {:stream_data, _event_name} ->
        increment(store_key, {:receive_event, :stream_data})
        increment(store_key, {:receive_event, :stream_data_bytes}, measurements[:byte_size] || 0)

      {:datagram, _event_name} ->
        increment(store_key, {:receive_event, :datagram})
        increment(store_key, {:receive_event, :datagram_bytes}, measurements[:byte_size] || 0)

      {:stream_event, event_name}
      when event_name in [:send_completed, :send_cancelled, :peer_finished_sending, :closed] ->
        increment(store_key, {:receive_event, {:stream_event, event_name}})

      _other ->
        increment(store_key, {:receive_event, :ignored})
    end
  end

  defp record_receive_result(store_key, _measurements, %{result: :timeout}) do
    increment(store_key, {:receive_event, :timeouts})
  end

  defp record_receive_result(store_key, _measurements, %{result: :unknown}) do
    increment(store_key, {:receive_event, :unknown})
  end

  defp record_receive_result(store_key, _measurements, %{result: :error}) do
    increment(store_key, {:receive_event, :errors})
  end

  defp record_receive_result(_store_key, _measurements, _metadata), do: :ok

  defp datagram_sender_snapshot(collector) do
    %{
      runs_started: counter(collector, {:datagram_sender, :runs_started}),
      runs_stopped: counter(collector, {:datagram_sender, :runs_stopped}),
      runs_failed: counter(collector, {:datagram_sender, :runs_failed}),
      demand_asked: counter(collector, {:datagram_sender, :demand_asked}),
      payloads_enqueued: counter(collector, {:datagram_sender, :payloads_enqueued}),
      ticks: counter(collector, {:datagram_sender, :ticks}),
      due: counter(collector, {:datagram_sender, :due}),
      sent: counter(collector, {:datagram_sender, :sent}),
      accepted: counter(collector, {:datagram_sender, :accepted}),
      errors: counter(collector, {:datagram_sender, :errors}),
      send_error_events: counter(collector, {:datagram_sender, :send_error_events}),
      capped_ticks: counter(collector, {:datagram_sender, :capped_ticks}),
      tool_limited_ticks: counter(collector, {:datagram_sender, :tool_limited_ticks}),
      burst_durations_us: duration_values(collector, :datagram_sender_burst)
    }
  end

  defp add_duration(_store, _key, nil), do: :ok

  defp add_duration(%{table: table}, key, duration_us) do
    :ets.insert(table, {{:duration, key, System.unique_integer([:monotonic])}, duration_us})
    :ok
  end

  defp duration_values(%__MODULE__{table: table}, key) do
    table
    |> :ets.match_object({{:duration, key, :_}, :_})
    |> Enum.map(fn {{:duration, ^key, sequence}, duration_us} -> {sequence, duration_us} end)
    |> Enum.sort_by(fn {sequence, _duration_us} -> sequence end)
    |> Enum.map(fn {_sequence, duration_us} -> duration_us end)
  end

  defp increment(%{table: table}, key, amount \\ 1) do
    :ets.update_counter(table, {:counter, key}, {2, amount}, {{:counter, key}, 0})
    :ok
  end

  defp counter(%__MODULE__{table: table}, key) do
    case :ets.lookup(table, {:counter, key}) do
      [{{:counter, ^key}, value}] -> value
      [] -> 0
    end
  end

  defp init_owner_store(store_key) do
    Enum.each(@duration_keys, fn key ->
      Process.put(duration_key(store_key, key), [])
    end)

    Enum.each(@counter_keys, fn key ->
      Process.put(counter_key(store_key, key), 0)
    end)
  end

  defp clear_owner_store(store_key) do
    Enum.each(@duration_keys, fn key ->
      Process.delete(duration_key(store_key, key))
    end)

    Enum.each(@counter_keys, fn key ->
      Process.delete(counter_key(store_key, key))
    end)
  end

  defp duration_key(store_key, key), do: {store_key, :duration, key}
  defp counter_key(store_key, key), do: {store_key, :counter, key}

  defp maybe_start_sampler(_table, _owner_pid, _started_at_us, false), do: {nil, nil, nil}

  defp maybe_start_sampler(table, owner_pid, started_at_us, true) do
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        sampler_loop(table, owner_pid, started_at_us, ref)
      end)

    {pid, ref, monitor_ref}
  end

  defp sampler_loop(table, owner_pid, started_at_us, ref) do
    sample_process(table, owner_pid, started_at_us)

    receive do
      {:stop_sampler, ^ref, caller} ->
        send(caller, {:sampler_stopped, ref})
        :ok
    after
      @sample_interval_ms -> sampler_loop(table, owner_pid, started_at_us, ref)
    end
  end

  defp stop_sampler(%__MODULE__{sampler_pid: nil}), do: :ok

  defp stop_sampler(%__MODULE__{
         sampler_pid: pid,
         sampler_ref: ref,
         sampler_monitor_ref: monitor_ref
       }) do
    send(pid, {:stop_sampler, ref, self()})

    receive do
      {:sampler_stopped, ^ref} ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :ok
    after
      @sample_interval_ms * 2 ->
        Process.demonitor(monitor_ref, [:flush])
        :ok
    end
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
