# Build paced DATAGRAM benchmark client

Status: in-progress
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/40-improve-moqx-client-datagram-paced-send-throughput.md`

## What to build

Extract the MOQX-client DATAGRAM pressure sender out of the monolithic
`reference-comparison` loop into a caller-side benchmark client with an explicit
payload pipeline and a paced send sink.

The client should model the first production use of `moqx`: a caller publishing
or subscribing against an external relay. Listener/relay-side benchmark clients
come later. This slice is about making the sender accurate, observable, and
fast enough to drive real QUIC paths without making the benchmark harness the
bottleneck.

The desired shape is:

```text
payload producer(s) -> paced DATAGRAM sink -> MOQX.Transport.send_datagram/3
```

Flow or GenStage may be used upstream to prepare payloads and control bounded
demand. The final paced sink must be a single process that owns
`MOQX.Transport.send_datagram/3` calls for one QUIC connection. It should use
absolute monotonic deadlines, send small bounded bursts per tick, and record
when it cannot keep up instead of hiding scheduler slips behind unbounded
catch-up bursts.

## Scope

- Add a reusable benchmark DATAGRAM client under the `bench/moqxprobe`
  sub-project.
- Keep it caller-side only: connect to a reference or MOQX listener and send
  DATAGRAM pressure; do not redesign listeners or relays in this issue.
- Support payload modes needed by current and near-future tests:
  - fixed payload reuse for sender-admission style calibration;
  - sequence/timestamp encoded payloads for delivery and latency measurement;
  - optional prefilled random payload rings if non-repeating bytes are needed.
- Use Flow/GenStage only where it improves producer/demand structure. Pacing
  belongs in the final sink, not in a parallel Flow stage.
- Emit benchmark-owned telemetry events under `[:moqx, :transport_bench, ...]`
  for sender lifecycle, demand/backlog, tick lag, due count, sent count,
  capped ticks, send burst duration, send errors, and queue depth.
- Preserve the existing `transport-bench-v1` step summary contract by adapting
  the new client output back into the current report fields.

## Acceptance criteria

- [ ] The DATAGRAM pressure sender is encapsulated behind a benchmark client
      module with explicit options and no mutable `Application` environment
      seam.
- [ ] Pure scheduler math is covered by tests: absolute deadlines, due count,
      burst cap, capped catch-up, no drift from "work time plus sleep time",
      and target-rate accounting.
- [ ] The paced sink is covered with a fake send function and can prove
      accepted count, send errors, tick lag, capped ticks, and final stop
      reason without opening a QUIC connection.
- [ ] Payload production is bounded by demand/backlog settings and does not
      allocate or read random bytes in the hot send loop.
- [ ] The final sink is the only process that calls
      `MOQX.Transport.send_datagram/3` for a connection.
- [ ] Benchmark telemetry events are emitted with low-cardinality metadata and
      can be collected by the existing benchmark collector or a small dedicated
      collector without synchronous GenServer/Agent calls on the hot path.
- [ ] `reference-comparison` DATAGRAM pressure uses the new client path while
      preserving `transport-bench-v1` fields for accepted sends, offered rate,
      offered-rate validity, delivery, drops, send timing, pacing lag, and
      diagnostics.
- [ ] Local loopback calibration demonstrates that the new client can sustain
      the 32k pps offered-rate contract with a valid negotiated DATAGRAM size,
      while clearly marking the result as loopback calibration only.
- [ ] Documentation explains the client architecture, payload modes, pacing
      rules, telemetry events, and when to use it instead of the lower-level
      `sender-admission` microbenchmark.

## Blocked by

None. #40 established that local BEAM-to-NIF DATAGRAM admission is fast enough
at 32k pps when the offered load is shaped correctly, and that the next
optimization target is the benchmark sender shape rather than the public
transport facade.

## Notes

This issue is not about implementing a relay or listener performance harness.
For v1, `moqx` is being optimized first as a caller: publish to a relay,
subscribe from a relay, and apply controlled caller-side pressure to external
peers.

Do not use `/dev/random` or per-packet random generation in the timed hot path.
If random-looking payload bytes are needed, prefill a bounded ring before the
measured phase and account for that setup separately.

Unbounded catch-up is a measurement bug. If the sink wakes late, it may send a
bounded catch-up burst and should record the capped tick. Past a configured
threshold, the run should be marked as tool-limited or offered-rate invalid
rather than presented as network capacity evidence.

## Progress

- 2026-06-05: Started implementation by extracting the dependency-free
  `MOQXProbe.Traffic` namespace and pure `MOQXProbe.Traffic.Pacer`. The pacer
  covers absolute elapsed-time target accounting, absolute deadline increments
  from the previous scheduled tick, bounded catch-up bursts, tool-limited lag
  detection, and final count clamping. This is the shared timing core for both
  the upcoming DATAGRAM sink and stream sink.
- 2026-06-05: Added the first DATAGRAM client components under
  `MOQXProbe.Traffic`: `PayloadFlow` builds bounded Flow payload pipelines
  with explicit demand options, and `DatagramSink` is a GenStage consumer that
  owns queued DATAGRAM admission, fake-send test seams, accepted/error counts,
  burst accounting, capped/tool-limited pacer outcomes, and producer-limited
  detection. This slice proves the Flow/GenStage split with deterministic
  tests; `ReferenceComparison` is not wired through it yet.
- 2026-06-05: Added `MOQXProbe.Traffic.StreamSink` as the sibling stream
  GenStage consumer. The first tests cover per-stream send-window enforcement,
  explicit send-completion feedback, error accounting, and FIN ordering by
  requiring the final payload to carry `finish: true` only after earlier
  payloads for the stream have been admitted. The pacer now also accepts an
  explicit "currently available work" cap so window-blocked streams do not
  consume unsent offered slots. `ReferenceComparison` extraction remains the
  next implementation step.
- 2026-06-05: Filled in the top-level `MOQXProbe.Traffic` module with a
  `feed_payloads/3` helper that runs a bounded Flow payload pipeline into an
  already-running GenStage sink and waits for the finite Flow coordinator to
  finish. `DatagramSink` and `StreamSink` now also expose `run/1` self-paced
  loops using absolute `Process.send_after(..., abs: true)` timers; deterministic
  tests inject timer and clock functions. The remaining extraction step is to
  replace the old `ReferenceComparison` DATAGRAM and stream send loops with
  these Traffic components while preserving `transport-bench-v1`.
