defmodule MOQXProbe.Telemetry do
  @moduledoc false

  import Telemetry.Metrics

  @stream_send_event [:moqx, :transport, :stream, :send, :stop]
  @stream_recv_event [:moqx, :transport, :stream, :recv, :stop]
  @datagram_send_event [:moqx, :transport, :datagram, :send, :stop]
  @receive_event [:moqx, :transport, :event, :receive, :stop]

  def metrics do
    [
      counter("moqx.transport.stream.send.stop.count",
        event_name: @stream_send_event,
        tags: [:result, :stream_direction, :local_role]
      ),
      sum("moqx.transport.stream.send.stop.bytes",
        event_name: @stream_send_event,
        measurement: :byte_size,
        tags: [:result, :stream_direction, :local_role]
      ),
      summary("moqx.transport.stream.send.stop.duration.us",
        event_name: @stream_send_event,
        measurement: :duration_us,
        tags: [:result, :stream_direction, :local_role]
      ),
      counter("moqx.transport.stream.recv.stop.count",
        event_name: @stream_recv_event,
        tags: [:result, :stream_direction, :local_role]
      ),
      sum("moqx.transport.stream.recv.stop.bytes",
        event_name: @stream_recv_event,
        measurement: :byte_size,
        tags: [:result, :stream_direction, :local_role]
      ),
      summary("moqx.transport.stream.recv.stop.duration.us",
        event_name: @stream_recv_event,
        measurement: :duration_us,
        tags: [:result, :stream_direction, :local_role]
      ),
      counter("moqx.transport.datagram.send.stop.count",
        event_name: @datagram_send_event,
        tags: [:result, :local_role]
      ),
      sum("moqx.transport.datagram.send.stop.bytes",
        event_name: @datagram_send_event,
        measurement: :byte_size,
        tags: [:result, :local_role]
      ),
      summary("moqx.transport.datagram.send.stop.duration.us",
        event_name: @datagram_send_event,
        measurement: :duration_us,
        tags: [:result, :local_role]
      ),
      counter("moqx.transport.event.receive.stop.count",
        event_name: @receive_event,
        tags: [:result, :event_kind, :event_name, :local_role]
      ),
      sum("moqx.transport.event.receive.stop.bytes",
        event_name: @receive_event,
        measurement: :byte_size,
        tags: [:result, :event_kind, :local_role]
      ),
      summary("moqx.transport.event.receive.stop.duration.us",
        event_name: @receive_event,
        measurement: :duration_us,
        tags: [:result, :event_kind, :event_name, :local_role]
      )
    ]
  end
end
