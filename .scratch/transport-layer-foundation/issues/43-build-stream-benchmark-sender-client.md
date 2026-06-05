# Build stream benchmark sender client

Status: done
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Extract the MOQX-client stream-pressure sender out of the monolithic
`measure` loop into a caller-side benchmark client with bounded
payload production, a single final stream sink, and benchmark-owned telemetry.

The desired shape mirrors the DATAGRAM sender while preserving stream-specific
feedback:

```text
payload descriptors -> bounded stream sink -> MOQX.Transport.send_stream/4
                                      ^ send-completion feedback
```

The active receive/event loop should remain responsible for peer echo, stream
data validation, timeout/failure classification, and the existing
`transport-bench-v1` report contract. The new sender owns send admission,
per-stream window pressure, FIN placement, bounded producer demand, and
send-completion feedback into the sink.

## Acceptance criteria

- [x] `MOQXProbe.Traffic.StreamSender` exists with explicit options and no
      mutable `Application` environment seam.
- [x] `StreamSink` uses bounded producer demand/backlog settings for Flow-fed
      payload descriptors.
- [x] The final sink process is the process that invokes the stream send
      callback for benchmark stream pressure.
- [x] Stream sender telemetry is emitted under
      `[:moqx, :transport_bench, :stream_sender, ...]` with low-cardinality
      metadata for lifecycle, demand/backlog, tick/drain, send bursts, window
      limitation, send errors, queue depth, and in-flight sends.
- [x] The existing benchmark telemetry collector can harvest stream-sender
      events without synchronous GenServer/Agent calls on the hot path.
- [x] `measure --workload stream_pressure` uses the new sender for
      MOQX-client stream pressure while preserving current metrics,
      diagnostics, stream summaries, send-completion counts, send-call timing,
      and event-pump fields.
- [x] Bidirectional stream pressure continues to use receive-event feedback to
      reopen stream send windows and attach FIN only to the final payload per
      stream.
- [x] Unidirectional stream pressure continues to produce send-only records
      without requiring peer echo.
- [x] Tests cover the sender boundary, bounded producer behavior, telemetry,
      and measure report compatibility.

## Notes

This issue is scoped to pure `stream_pressure`. Mixed MOQT-shaped object/control
traffic still has its own scheduler and can be migrated in a later issue once
the stream sender is proven on the simpler workload.

## Progress

- 2026-06-05: Started after #41 completed the DATAGRAM sender extraction.
  Current state before edits: `StreamSink` exists with unit tests for send
  windows, send errors, send completions, and FIN ordering, but
  `Measure` still calls `MOQX.Transport.send_stream/4` directly in
  its stream-pressure scheduling loop.
- 2026-06-05: Implemented `MOQXProbe.Traffic.StreamSender` and migrated pure
  `measure --workload stream_pressure` onto it. The sender uses a
  bounded Flow producer and a single stream sink, carries the transport context
  and per-stream diagnostics state, reopens windows from send-completion
  feedback, and preserves the existing stream-pressure diagnostic/report
  fields. Stream-sender telemetry is emitted and harvested by
  `TransportTelemetryCollector`. Focused verification passed:
  `mix test test/moqxprobe/traffic/stream_sender_test.exs
  test/moqxprobe/traffic/stream_sink_test.exs
  test/moqxprobe/transport_telemetry_collector_test.exs` and
  `mix test test/moqxprobe/measure_test.exs`.
