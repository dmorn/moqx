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
    [:moqx, :transport_bench, :datagram_sender, :send, :error],
    [:moqx, :transport_bench, :stream_sender, :run, :start],
    [:moqx, :transport_bench, :stream_sender, :run, :stop],
    [:moqx, :transport_bench, :stream_sender, :demand, :ask],
    [:moqx, :transport_bench, :stream_sender, :backlog, :change],
    [:moqx, :transport_bench, :stream_sender, :tick, :stop],
    [:moqx, :transport_bench, :stream_sender, :send, :error]
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
    :datagram_sender_burst,
    :stream_sender_burst
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
    {:datagram_sender, :tool_limited_ticks},
    {:stream_sender, :runs_started},
    {:stream_sender, :runs_stopped},
    {:stream_sender, :runs_failed},
    {:stream_sender, :demand_asked},
    {:stream_sender, :payloads_enqueued},
    {:stream_sender, :ticks},
    {:stream_sender, :due},
    {:stream_sender, :sent},
    {:stream_sender, :accepted},
    {:stream_sender, :completed},
    {:stream_sender, :errors},
    {:stream_sender, :send_error_events},
    {:stream_sender, :capped_ticks},
    {:stream_sender, :tool_limited_ticks},
    {:stream_sender, :stream_window_limited_ticks}
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
    enable_scheduler_wall_time(table)
    :ets.insert(table, {:beam_runtime_start, beam_runtime_snapshot(owner_pid)})

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
        beam: beam_runtime_diagnostics(collector),
        datagram_sender: datagram_sender_snapshot(collector),
        stream_sender: stream_sender_snapshot(collector)
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

  defp do_handle_event(
         [:moqx, :transport_bench, :stream_sender, :run, :start],
         _measurements,
         _metadata,
         store_key
       ) do
    increment(store_key, {:stream_sender, :runs_started})
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :stream_sender, :run, :stop],
         measurements,
         metadata,
         store_key
       ) do
    increment(store_key, {:stream_sender, :runs_stopped})
    increment(store_key, {:stream_sender, :completed}, measurements[:completed_count] || 0)

    if metadata[:result] == :error do
      increment(store_key, {:stream_sender, :runs_failed})
    end
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :stream_sender, :demand, :ask],
         measurements,
         _metadata,
         store_key
       ) do
    increment(store_key, {:stream_sender, :demand_asked}, measurements[:demand_count] || 0)
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :stream_sender, :backlog, :change],
         measurements,
         _metadata,
         store_key
       ) do
    increment(
      store_key,
      {:stream_sender, :payloads_enqueued},
      measurements[:enqueued_count] || 0
    )
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :stream_sender, :tick, :stop],
         measurements,
         _metadata,
         store_key
       ) do
    increment(store_key, {:stream_sender, :ticks})
    increment(store_key, {:stream_sender, :due}, measurements[:due_count] || 0)
    increment(store_key, {:stream_sender, :sent}, measurements[:send_count] || 0)
    increment(store_key, {:stream_sender, :accepted}, measurements[:accepted_count] || 0)
    increment(store_key, {:stream_sender, :errors}, measurements[:error_count] || 0)
    increment(store_key, {:stream_sender, :capped_ticks}, measurements[:capped_tick_count] || 0)

    increment(
      store_key,
      {:stream_sender, :tool_limited_ticks},
      measurements[:tool_limited_tick_count] || 0
    )

    increment(
      store_key,
      {:stream_sender, :stream_window_limited_ticks},
      measurements[:stream_window_limited_tick_count] || 0
    )

    add_duration(store_key, :stream_sender_burst, measurements[:burst_duration_us])
  end

  defp do_handle_event(
         [:moqx, :transport_bench, :stream_sender, :send, :error],
         measurements,
         _metadata,
         store_key
       ) do
    increment(store_key, {:stream_sender, :send_error_events}, measurements[:error_count] || 0)
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

  defp stream_sender_snapshot(collector) do
    %{
      runs_started: counter(collector, {:stream_sender, :runs_started}),
      runs_stopped: counter(collector, {:stream_sender, :runs_stopped}),
      runs_failed: counter(collector, {:stream_sender, :runs_failed}),
      demand_asked: counter(collector, {:stream_sender, :demand_asked}),
      payloads_enqueued: counter(collector, {:stream_sender, :payloads_enqueued}),
      ticks: counter(collector, {:stream_sender, :ticks}),
      due: counter(collector, {:stream_sender, :due}),
      sent: counter(collector, {:stream_sender, :sent}),
      accepted: counter(collector, {:stream_sender, :accepted}),
      completed: counter(collector, {:stream_sender, :completed}),
      errors: counter(collector, {:stream_sender, :errors}),
      send_error_events: counter(collector, {:stream_sender, :send_error_events}),
      capped_ticks: counter(collector, {:stream_sender, :capped_ticks}),
      tool_limited_ticks: counter(collector, {:stream_sender, :tool_limited_ticks}),
      stream_window_limited_ticks:
        counter(collector, {:stream_sender, :stream_window_limited_ticks}),
      burst_durations_us: duration_values(collector, :stream_sender_burst)
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
    run_queue = statistics_value(:run_queue)
    total_active_tasks = statistics_value(:total_active_tasks)
    total_active_tasks_all = statistics_value(:total_active_tasks_all)
    sample_index = increment_sample_count(table)
    update_message_queue_peak(table, message_queue_len)
    update_peak(table, :run_queue_peak, run_queue)
    update_peak(table, :total_active_tasks_peak, total_active_tasks)
    update_peak(table, :total_active_tasks_all_peak, total_active_tasks_all)

    if keep_message_queue_sample?(sample_index) do
      :ets.insert(table, {
        {:message_queue_sample, sample_index},
        compact(%{
          "sample_index" => sample_index,
          "elapsed_ms" => (monotonic_us() - started_at_us) / 1000,
          "message_queue_len" => message_queue_len,
          "run_queue" => run_queue,
          "total_active_tasks" => total_active_tasks,
          "total_active_tasks_all" => total_active_tasks_all
        })
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
    update_peak(table, :message_queue_len_peak, message_queue_len)
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

  defp update_peak(_table, _key, nil), do: :ok

  defp update_peak(table, key, value) do
    peak =
      case :ets.lookup(table, key) do
        [{^key, current}] -> max(current, value)
        [] -> value
      end

    :ets.insert(table, {key, peak})
  end

  defp enable_scheduler_wall_time(table) do
    enabled_before =
      try do
        :erlang.system_flag(:scheduler_wall_time, true)
      catch
        _kind, _reason -> :unavailable
      end

    :ets.insert(table, {:scheduler_wall_time_enabled_before, enabled_before})
  end

  defp beam_runtime_diagnostics(%__MODULE__{table: table, owner_pid: owner_pid}) do
    started = scalar(table, :beam_runtime_start, %{})
    finished = beam_runtime_snapshot(owner_pid)

    compact(%{
      "schedulers_online" => finished["schedulers_online"],
      "dirty_cpu_schedulers" => finished["dirty_cpu_schedulers"],
      "dirty_io_schedulers" => finished["dirty_io_schedulers"],
      "scheduler_wall_time_enabled_before" => scalar(table, :scheduler_wall_time_enabled_before),
      "scheduler_wall_time" =>
        scheduler_wall_time_diagnostics(
          started["scheduler_wall_time"],
          finished["scheduler_wall_time"]
        ),
      "run_queue" =>
        delta_peak_diagnostics(
          started["run_queue"],
          finished["run_queue"],
          scalar(table, :run_queue_peak)
        ),
      "total_active_tasks" =>
        delta_peak_diagnostics(
          started["total_active_tasks"],
          finished["total_active_tasks"],
          scalar(table, :total_active_tasks_peak)
        ),
      "total_active_tasks_all" =>
        delta_peak_diagnostics(
          started["total_active_tasks_all"],
          finished["total_active_tasks_all"],
          scalar(table, :total_active_tasks_all_peak)
        ),
      "total_run_queue_lengths_delta" =>
        numeric_delta(started["total_run_queue_lengths"], finished["total_run_queue_lengths"]),
      "reductions_delta" => numeric_delta(started["reductions"], finished["reductions"]),
      "context_switches_delta" =>
        numeric_delta(started["context_switches"], finished["context_switches"]),
      "garbage_collection_count_delta" =>
        numeric_delta(
          started["garbage_collection_count"],
          finished["garbage_collection_count"]
        ),
      "garbage_collection_words_reclaimed_delta" =>
        numeric_delta(
          started["garbage_collection_words_reclaimed"],
          finished["garbage_collection_words_reclaimed"]
        ),
      "owner_process" => process_runtime_diagnostics(started["process"], finished["process"])
    })
  end

  defp beam_runtime_snapshot(owner_pid) do
    {garbage_collection_count, garbage_collection_words_reclaimed} = garbage_collection_stats()

    compact(%{
      "monotonic_us" => monotonic_us(),
      "schedulers_online" => system_info(:schedulers_online),
      "dirty_cpu_schedulers" => system_info(:dirty_cpu_schedulers),
      "dirty_io_schedulers" => system_info(:dirty_io_schedulers),
      "scheduler_wall_time" => scheduler_wall_time(),
      "run_queue" => statistics_value(:run_queue),
      "total_run_queue_lengths" => statistics_value(:total_run_queue_lengths),
      "total_active_tasks" => statistics_value(:total_active_tasks),
      "total_active_tasks_all" => statistics_value(:total_active_tasks_all),
      "reductions" => reductions_total(),
      "context_switches" => context_switches_total(),
      "garbage_collection_count" => garbage_collection_count,
      "garbage_collection_words_reclaimed" => garbage_collection_words_reclaimed,
      "process" => process_runtime_snapshot(owner_pid)
    })
  end

  defp process_runtime_snapshot(pid) do
    compact(%{
      "reductions" => process_info_value(pid, :reductions),
      "memory_bytes" => process_info_value(pid, :memory),
      "total_heap_size_words" => process_info_value(pid, :total_heap_size),
      "heap_size_words" => process_info_value(pid, :heap_size),
      "stack_size_words" => process_info_value(pid, :stack_size),
      "message_queue_len" => message_queue_len(pid)
    })
  end

  defp process_runtime_diagnostics(started, finished) when is_map(started) and is_map(finished) do
    compact(%{
      "reductions_delta" => numeric_delta(started["reductions"], finished["reductions"]),
      "memory_bytes_start" => started["memory_bytes"],
      "memory_bytes_finish" => finished["memory_bytes"],
      "memory_bytes_delta" => numeric_delta(started["memory_bytes"], finished["memory_bytes"]),
      "total_heap_size_words_start" => started["total_heap_size_words"],
      "total_heap_size_words_finish" => finished["total_heap_size_words"],
      "total_heap_size_words_delta" =>
        numeric_delta(started["total_heap_size_words"], finished["total_heap_size_words"]),
      "heap_size_words_finish" => finished["heap_size_words"],
      "stack_size_words_finish" => finished["stack_size_words"],
      "message_queue_len_start" => started["message_queue_len"],
      "message_queue_len_finish" => finished["message_queue_len"]
    })
  end

  defp process_runtime_diagnostics(_started, _finished), do: %{}

  defp scheduler_wall_time do
    case statistics_value(:scheduler_wall_time) do
      value when is_list(value) -> value
      _other -> nil
    end
  end

  defp scheduler_wall_time_diagnostics(started, finished)
       when is_list(started) and is_list(finished) do
    started_by_id = Map.new(started, fn {id, active, total} -> {id, {active, total}} end)

    deltas =
      finished
      |> Enum.flat_map(&scheduler_wall_time_delta(&1, started_by_id))

    active_delta = deltas |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    total_delta = deltas |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    utilizations = Enum.map(deltas, &elem(&1, 3)) |> Enum.sort()

    compact(%{
      "entry_count" => length(deltas),
      "active_time_delta" => active_delta,
      "total_time_delta" => total_delta,
      "utilization_percent" => percent(active_delta, total_delta),
      "utilization_p50_percent" => percentile(utilizations, 0.50),
      "utilization_p95_percent" => percentile(utilizations, 0.95),
      "utilization_p99_percent" => percentile(utilizations, 0.99),
      "utilization_max_percent" => List.last(utilizations)
    })
  end

  defp scheduler_wall_time_diagnostics(_started, _finished), do: %{}

  defp scheduler_wall_time_delta({id, active, total}, started_by_id) do
    case Map.fetch(started_by_id, id) do
      {:ok, {started_active, started_total}} ->
        maybe_scheduler_wall_time_delta(
          id,
          active - started_active,
          total - started_total
        )

      :error ->
        []
    end
  end

  defp maybe_scheduler_wall_time_delta(_id, _active_delta, total_delta)
       when total_delta <= 0,
       do: []

  defp maybe_scheduler_wall_time_delta(id, active_delta, total_delta) do
    [{id, active_delta, total_delta, active_delta * 100 / total_delta}]
  end

  defp delta_peak_diagnostics(started, finished, peak) do
    compact(%{
      "start" => started,
      "finish" => finished,
      "delta" => numeric_delta(started, finished),
      "peak" => peak
    })
  end

  defp reductions_total do
    case statistics_value(:reductions) do
      {total, _since_last} -> total
      _other -> nil
    end
  end

  defp context_switches_total do
    case statistics_value(:context_switches) do
      {total, _since_last} -> total
      _other -> nil
    end
  end

  defp garbage_collection_stats do
    case statistics_value(:garbage_collection) do
      {count, words_reclaimed, _since_last} -> {count, words_reclaimed}
      _other -> {nil, nil}
    end
  end

  defp statistics_value(key) do
    :erlang.statistics(key)
  catch
    _kind, _reason -> nil
  end

  defp system_info(key) do
    :erlang.system_info(key)
  catch
    _kind, _reason -> nil
  end

  defp process_info_value(pid, key) do
    case Process.info(pid, key) do
      {^key, value} -> value
      nil -> nil
    end
  end

  defp numeric_delta(started, finished) when is_number(started) and is_number(finished),
    do: finished - started

  defp numeric_delta(_started, _finished), do: nil

  defp percent(_numerator, denominator) when denominator in [nil, 0], do: nil
  defp percent(numerator, denominator), do: numerator * 100 / denominator

  defp percentile([], _p), do: nil
  defp percentile([value], _p), do: value

  defp percentile(sorted, p) do
    index = trunc((length(sorted) - 1) * p)
    Enum.at(sorted, index)
  end

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc when is_map(value) ->
        compacted = compact(value)
        if compacted == %{}, do: acc, else: Map.put(acc, key, compacted)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
end
