defmodule MOQXProbe.Traffic.StreamPartitionSinkTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.BackendRef
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info
  alias MOQXProbe.Traffic
  alias MOQXProbe.Traffic.StreamPartitionSink

  defmodule FakeBackend do
    @moduledoc false

    def send_stream(raw_stream, _data, _opts) do
      send(self(), {:fake_stream_event, raw_stream, :send_complete, false})
      :ok
    end

    def normalize_message({:fake_stream_event, raw_stream, event, cancelled?}) do
      {:stream_event, raw_stream, event, cancelled?}
    end

    def normalize_message(_message), do: :unknown
  end

  test "partition sinks stop normally after source EOF and send completions drain" do
    streams = Enum.map(1..2, &stream/1)

    {:ok, sink_0} =
      StreamPartitionSink.start_link(
        partition: 0,
        shard_index: 1,
        streams: [Enum.at(streams, 0)],
        payload_count: 2,
        stream_send_window: 1,
        max_queue_depth: 2,
        notify_pid: self()
      )

    {:ok, sink_1} =
      StreamPartitionSink.start_link(
        partition: 1,
        shard_index: 2,
        streams: [Enum.at(streams, 1)],
        payload_count: 2,
        stream_send_window: 1,
        max_queue_depth: 2,
        notify_pid: self()
      )

    events =
      Enum.flat_map(1..2, fn payload_index ->
        Enum.map(streams, fn %{stream: stream, index: stream_index} ->
          %{
            stream: stream,
            stream_index: stream_index,
            payload: "payload-#{payload_index}",
            payload_index: payload_index,
            finish?: payload_index == 2
          }
        end)
      end) ++
        for partition <- 0..1 do
          %{control: :source_eof, partition: partition}
        end

    hash = fn
      %{control: :source_eof, partition: partition} = event ->
        {event, partition}

      event ->
        {event, rem(event.stream_index - 1, 2)}
    end

    {:ok, producer} =
      Traffic.start_partitioned_payloads(events, [{0, sink_0}, {1, sink_1}],
        mapper: & &1,
        stages: 1,
        partition_count: 2,
        hash: hash,
        min_demand: 1,
        max_demand: 2
      )

    assert_receive {:moqxprobe_stream_partition_sink_done, ^sink_0, 0,
                    %{
                      completed: 2,
                      source_eof_events: 1,
                      upstream_closed?: true,
                      queue_depth: 0,
                      in_flight: 0
                    }},
                   1_000

    assert_receive {:moqxprobe_stream_partition_sink_done, ^sink_1, 1,
                    %{
                      completed: 2,
                      source_eof_events: 1,
                      upstream_closed?: true,
                      queue_depth: 0,
                      in_flight: 0
                    }},
                   1_000

    assert :ok = Traffic.await_payloads(producer, 1_000)
  end

  defp stream(index) do
    %{
      stream: %Stream{
        backend: %BackendRef{module: FakeBackend, data: {:fake_stream, index}},
        info: %Info{
          stream_id: index,
          direction: :unidirectional,
          initiator: :self,
          initiator_role: :client,
          local_role: :client,
          send_side?: true,
          receive_side?: false
        }
      },
      index: index
    }
  end
end
