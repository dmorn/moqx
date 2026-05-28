# Design telemetry-backed benchmark measurement pipeline

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Design the next measurement layer for transport pressure work so benchmark
diagnostics become structured, layered, and cheap enough to leave enabled while
iterating on performance.

#37 proved that benchmark-side observer cost can become the bottleneck: the
slow path was not QUIC, `send_stream/4`, `receive_event/2`, or the reference
peer, but synchronous diagnostics and payload validation in the benchmark
caller. The next measurement design must make that kind of distortion harder
to reintroduce.

This issue is a design and contract slice. Do not build a full remote
collector, dashboard, or daemon here unless the design explicitly splits that
work into follow-up issues.

## Scope

- Define a layered `:telemetry` event taxonomy:
  - `[:moqx, :transport, ...]` for stable library-level transport events.
  - `[:moqx, :transport_bench, ...]` for benchmark run, path, step, workload,
    and role lifecycle events.
  - `[:moqx, :transport_bench, :system, ...]` for runtime observations such as
    process mailbox depth, scheduler pressure, reductions, memory, and host
    metadata.
- Define the hot-path collection model:
  - first implementation should be an in-process collector attached for a run
    or step;
  - per-event handling must avoid synchronous GenServer or Agent calls in the
    pressure path;
  - aggregation should use cheap counters, histograms, summaries, ETS, or
    process-local batching where appropriate;
  - no payload copies and no byte-by-byte validation in telemetry handlers.
- Define artifact boundaries:
  - the current `transport-bench-v1` JSONL step summaries remain the stable
    machine-readable contract for reports and issue evidence;
  - richer metrics, traces, and logs should be sidecar artifacts or remote
    collector data, linked by run id, path id, step id, profile, topology, and
    workload;
  - every run should be reconstructable after disposable infrastructure is
    destroyed.
- Define remote collection as a later phase:
  - local collector first;
  - optional collector service over the Tailnet later;
  - optional Prometheus/OpenMetrics/Grafana integration later;
  - possible future `moqx_transport_benchd` API/daemon later, if that still
    reduces operational friction after the local collector exists.

## Acceptance criteria

- [x] A benchmark measurement design is documented in `bench/transport/README.md`
      or a dedicated ADR, with the README linking to it.
- [x] The design defines the telemetry event hierarchy, event names,
      measurements, metadata, and cardinality rules.
- [x] The design explicitly separates stable transport-library telemetry from
      benchmark-only telemetry.
- [x] The design forbids high-cardinality labels such as per-payload indexes or
      raw stream ids in metrics meant for Prometheus-style exporters.
- [x] The design preserves the existing compact `transport-bench-v1` JSONL
      report contract and explains which data moves to sidecars.
- [x] The design defines the first in-process collector implementation slice
      and its overhead budget.
- [x] The design records how run metadata, logs, diagnostics, and result
      bundles survive infrastructure teardown.
- [x] Follow-up implementation issues are opened for the first collector slice
      and any remote collector or daemon work.
- [x] The design preserves explicit dependency seams and does not introduce
      `Application` environment as mutable configuration.

## Blocked by

None. Start from the #37 evidence that observer overhead can dominate a
transport pressure run.

## Notes

The goal is not more logging. The goal is a measurement plane that can answer
where time and queueing went without turning the observer into the workload.

Prefer keeping the report command simple: it should continue to summarize the
canonical JSONL records, then optionally include sidecar metric summaries when
the run bundle contains them.

## Settled Design Direction

Use `:telemetry` as the event bus and `telemetry_metrics` as the benchmark
metric definition layer, but keep the actual pressure-run collector
benchmark-specific.

Dependency split:

- root `moqx` may depend on `:telemetry` so `MOQX.Transport` can emit stable
  transport-library events;
- root `moqx` must not depend on `telemetry_metrics`;
- `bench/transport` may depend on `telemetry_metrics` and define the benchmark
  metric declarations;
- `bench/transport` owns the collector/reporter that turns those declarations
  into the existing benchmark measurement maps.

Emitter placement:

- emit stable transport events from `MOQX.Transport`, not directly from
  `MOQX.Transport.Quicer`, because the facade owns the normalized transport
  vocabulary consumed by protocol code;
- keep backend-specific metadata small and normalized;
- do not expose raw payloads, raw connection handles, or backend message shapes
  in stable transport-library events.

Initial transport events should focus on the hot paths needed by the first
refactor:

- `[:moqx, :transport, :stream, :send, :stop]`
- `[:moqx, :transport, :datagram, :send, :stop]`
- `[:moqx, :transport, :event, :receive, :stop]`

Benchmark events remain separate because they encode workload semantics the
library cannot know:

- offered payload/datagram counts;
- expected echo/delivery counts;
- stream pressure, DATAGRAM pressure, and mixed MOQT-shaped step lifecycle;
- control-stream latency and object-pressure success criteria.

Collector contract:

- attach for one run or step, then detach in `after`;
- use `telemetry_metrics` declarations as the metric schema;
- use a custom low-impact reporter/collector, not a generic Prometheus or
  StatsD reporter in the hot path;
- handler work must stay bounded: no synchronous `Agent` or GenServer calls,
  no file IO, no JSON encoding, no payload copies, and no per-event
  `Process.info/2` calls;
- aggregate with cheap counters, histograms, summaries, ETS, `:counters`, or
  equivalent process-local batching;
- return the same `moqx-reference-measurement-v1`-style measurement map that
  existing `reference-comparison` code already converts into
  `transport-bench-v1`.

First implementation slice:

- add the minimal transport emitters needed for MOQX-client stream pressure;
- add `MOQX.TransportBench.Telemetry.metrics/0` declarations for those events;
- add a benchmark collector/reporter that reconstructs the current stream
  diagnostics and timing summaries;
- move MOQX-client stream-pressure measurement onto the collector without
  changing workload behavior or the canonical `transport-bench-v1` summary
  output;
- leave DATAGRAM pressure, mixed pressure, remote collectors, dashboards, and a
  daemon for later slices.

## Comments

- 2026-05-28: Created after #37 showed that benchmark-side measurement
  overhead can cap throughput. This issue captures the agreed direction:
  layered telemetry first, cheap in-process collection first, stable JSONL
  summaries preserved, richer diagnostics as sidecars or later remote
  collector data.
- 2026-05-28: Settled the separation of concerns before implementation:
  `:telemetry` emitters belong at the root transport facade, `telemetry_metrics`
  belongs in the benchmark project as the metric declaration layer, and the
  pressure-run collector stays custom so it can produce the existing
  measurement map with bounded hot-path overhead.
- 2026-05-28: Closed after adding
  `docs/adr/0005-telemetry-backed-transport-benchmark-measurement.md` and
  linking it from the benchmark README. Follow-up #39 is the first
  implementation slice.
