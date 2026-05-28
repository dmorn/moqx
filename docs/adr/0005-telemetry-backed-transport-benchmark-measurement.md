# ADR-0005: Telemetry-backed transport benchmark measurement

- Status: Accepted
- Date: 2026-05-28

## Context

The transport benchmark harness exists to answer how far a real QUIC path can
be pushed before it degrades or fails, and how much of that path `moqx` can
fill under stream, DATAGRAM, and mixed MOQT-shaped pressure.

The benchmark already has a useful machine-readable contract:
`transport-bench-v1` JSONL records with path metadata, workload parameters,
metrics, limits, and errors. Reports, issue evidence, and future progress
dashboards should consume that contract instead of replacing it with a new
primary output format.

#37 showed that measurement code can distort the benchmark itself. The
stream-pressure bottleneck was not QUIC, `send_stream/4`, `receive_event/2`,
`quicer`, or the reference peer. The slow path was benchmark-side observer
overhead: live synchronous diagnostics and byte-by-byte payload validation in
the caller. Future measurement work must make this harder to repeat.

We want a standard measurement bus that can later feed local summaries,
sidecar artifacts, dashboards, or remote collectors, while keeping the first
refactor narrow: same workload behavior, same `transport-bench-v1` output,
different measurement plumbing.

## Decision

Use `:telemetry` as the event bus and `telemetry_metrics` as the benchmark
metric declaration layer. Keep the actual pressure-run collector custom and
benchmark-specific.

### Dependency Boundary

The root `moqx` library may depend on `:telemetry` so `MOQX.Transport` can emit
stable library events.

The root `moqx` library must not depend on `telemetry_metrics`.

The `bench/transport` Mix project may depend on `telemetry_metrics` and define
the metric declarations needed by benchmark tooling.

The `bench/transport` project owns the collector/reporter that turns emitted
events into the measurement maps already consumed by the existing
`transport-bench-v1` record builder.

### Output Contract

`transport-bench-v1` JSONL remains the canonical benchmark artifact.

The first telemetry refactor must preserve the existing report-facing output:
step summaries, key metrics, limits, errors, and current diagnostics must stay
semantically equivalent unless a later issue explicitly changes the contract.

The collector should first return the existing
`moqx-reference-measurement-v1`-style measurement maps used internally by
`reference-comparison`. The existing record builder can continue converting
those maps into `transport-bench-v1` JSONL.

Additional sidecar artifacts, remote collectors, or dashboards are optional
later phases. They must not be required for producing or reading the canonical
JSONL summary.

### Artifact Survival

Disposable infrastructure may be destroyed immediately after a run. Therefore
all evidence needed for later analysis must survive locally under the run
result directory before teardown.

For the first telemetry refactor, the required durable artifact remains the
canonical `transport-bench-v1` JSONL summary. That summary must continue to
carry enough run metadata to identify the run id, git SHA, command, path,
topology, workload, profile, client/server implementation, limits, and errors.

If later slices add metric sidecars, logs, traces, or a manifest, those
artifacts must be linked by the same run id and step identity used by the JSONL
summary. Sidecars are additive evidence, not replacements for the summary
contract.

### Event Placement

Stable transport events are emitted from `MOQX.Transport`, not directly from
`MOQX.Transport.Quicer`.

`MOQX.Transport` owns the normalized event vocabulary consumed by protocol
code. Emitting at the facade preserves the abstraction: library telemetry uses
transport concepts such as stream sends, DATAGRAM sends, normalized receive
events, roles, stream direction, and application-level result atoms. It does
not expose raw backend messages or raw `quicer` handles as stable event
metadata.

Backend-specific details may appear only as small normalized metadata values
where useful, such as `backend: MOQX.Transport.Quicer`.

### Initial Transport Events

Start with only the stable events needed by the first refactor.

#### `[:moqx, :transport, :stream, :send, :stop]`

Emitted once from `MOQX.Transport.send_stream/4` after the backend accepts or
rejects the send request.

Measurements:

- `duration_us`
- `byte_size`

Metadata:

- `backend`
- `result`: `:ok` or `:error`
- `reason`: normalized error reason or `nil`
- `finish?`
- `stream_id`
- `stream_direction`
- `stream_initiator`
- `local_role`

This event is send-admission evidence only. It is not peer-delivery proof.
Completion is still observed later through normalized receive events.

#### `[:moqx, :transport, :datagram, :send, :stop]`

Emitted once from `MOQX.Transport.send_datagram/3` after the backend accepts or
rejects the DATAGRAM send request.

Measurements:

- `duration_us`
- `byte_size`

Metadata:

- `backend`
- `result`: `:ok` or `:error`
- `reason`: normalized error reason or `nil`
- `local_role`

This event is local admission evidence only. It is not delivery evidence.

#### `[:moqx, :transport, :event, :receive, :stop]`

Emitted once from `MOQX.Transport.receive_event/2` after timeout, unknown
message handling, normalized event delivery, or normalization error.

Measurements:

- `duration_us`
- `timeout_ms`, or `nil` for `:infinity`
- `byte_size`, only when the normalized event carries stream data or a
  DATAGRAM payload

Metadata:

- `backend`
- `result`: `:ok`, `:timeout`, `:unknown`, or `:error`
- `event_kind`: `:stream_data`, `:datagram`, `:stream_event`,
  `:connection_event`, `:listener_event`, `:timeout`, `:unknown`, or `:error`
- `event_name`: normalized event atom where applicable
- `reason`: normalized error reason or `nil`
- `stream_id`, when the event belongs to a known stream
- `stream_direction`, when the event belongs to a known stream
- `stream_initiator`, when the event belongs to a known stream
- `local_role`, when known

Send completions remain modeled as normalized stream events. A collector can
count `event_kind: :stream_event` with `event_name: :send_completed` or
`:send_cancelled` and use the normalized send metadata to account for accepted
send tokens.

### Benchmark Events

Benchmark semantics remain separate from library transport telemetry. The
library cannot know what an offered load step, expected echo, control trickle,
or object-pressure success condition means.

Benchmark-owned events use the `[:moqx, :transport_bench, ...]` prefix.
Initial categories:

- `[:moqx, :transport_bench, :run, :start]`
- `[:moqx, :transport_bench, :run, :stop]`
- `[:moqx, :transport_bench, :step, :start]`
- `[:moqx, :transport_bench, :step, :stop]`
- `[:moqx, :transport_bench, :stream, :payload, :offered]`
- `[:moqx, :transport_bench, :stream, :echo, :received]`
- `[:moqx, :transport_bench, :datagram, :offered]`
- `[:moqx, :transport_bench, :datagram, :delivered]`
- `[:moqx, :transport_bench, :control, :message, :delivered]`

These events may carry run id, step id, topology, workload, profile, role, and
expected workload counts. They should not duplicate large transport payloads.

### Metric Declarations

`bench/transport` defines metric declarations with `Telemetry.Metrics`.

The declarations are the benchmark metric schema. They should describe the
counters, sums, summaries, and last values that the collector can aggregate
from transport and benchmark events.

Examples of first-slice metric declarations:

- stream send accepted count;
- stream send error count;
- stream send admitted bytes;
- stream send admission duration summary;
- receive-event call duration summary;
- normalized receive-event counts by event kind and event name;
- send completion and cancellation counts;
- stream data received bytes;
- benchmark echo bytes received;
- final or sampled sender mailbox depth, collected outside hot event handlers.

Do not use a generic Prometheus, StatsD, or dashboard reporter in pressure
loops for the first slice. Generic reporters can be added later if their
handler overhead and cardinality behavior are understood.

### Collector Contract

The benchmark collector attaches for one run or one step and detaches in
`after`.

Telemetry handlers run in the process that emits the event. Therefore handler
work is hot-path work. Handlers must be bounded and cheap:

- no file IO;
- no JSON encoding;
- no payload copies;
- no synchronous `Agent` updates;
- no synchronous GenServer calls;
- no per-event `Process.info/2` calls;
- no expensive formatting or exception rendering;
- no unbounded map growth keyed by payload indexes or raw handles.

Aggregation should use cheap counters, summaries, histograms, ETS,
`:counters`, or equivalent process-local batching. The collector may convert
aggregates into maps only at step end.

Mailbox depth, scheduler pressure, reductions, memory, and host/process
observations should be collected by a step-owned sampler process polling known
role pids at a fixed interval. They should not be sampled inside every
telemetry handler.

### Cardinality Rules

Allowed dimensions for benchmark aggregation:

- `run_id`
- `step_id`
- `role`
- `topology`
- `workload`
- `profile`
- `evidence_tier`
- `path_id`
- `client_implementation`
- `server_implementation`

Forbidden dimensions for metrics intended for dashboard or Prometheus-style
export:

- payload index;
- DATAGRAM sequence number;
- raw stream id;
- raw connection handle;
- raw listener handle;
- raw peer address per event;
- exception text;
- payload bytes.

Raw stream ids may be used inside a short-lived in-process collector when
needed to reconstruct per-stream benchmark state, but they must not become
high-cardinality exported metric labels.

### Implementation Order

1. Document this ADR and link it from the benchmark README.
2. Add root `:telemetry` emitters for the minimal stream-pressure path:
   `send_stream/4` and `receive_event/2`.
3. Add `telemetry_metrics` declarations under `bench/transport`.
4. Add a benchmark-owned collector that reconstructs the current MOQX-client
   stream-pressure measurement map.
5. Move MOQX-client stream-pressure measurement onto the collector without
   changing workload behavior or `transport-bench-v1` output.
6. Validate locally against the post-#37 stream-pressure path.
7. Migrate DATAGRAM pressure and mixed pressure only after the first stream
   slice is stable.
8. Consider sidecars, remote collectors, dashboards, or a benchmark daemon only
   after local collection proves useful and cheap.

## Consequences

Positive:

- Transport instrumentation uses the same normalized abstraction protocol code
  sees.
- Benchmark metrics become structured and reusable without replacing the
  existing JSONL evidence contract.
- The first implementation slice can prove that measurement plumbing can change
  while benchmark behavior and reports stay stable.
- Future dashboards or remote collectors can reuse the metric declarations
  instead of reverse-engineering ad-hoc diagnostics.

Tradeoffs:

- Root `moqx` gains a small runtime dependency on `:telemetry`.
- Telemetry handlers are synchronous, so collector implementation discipline is
  part of benchmark correctness.
- Some per-stream reconstruction may still be needed for benchmark semantics,
  but it must remain local to the collector and not leak as exported metric
  cardinality.

## Non-goals

This ADR does not implement:

- a remote collector;
- Prometheus/OpenMetrics export;
- Grafana dashboards;
- a persistent `moqx_transport_benchd` daemon;
- a new benchmark output schema replacing `transport-bench-v1`;
- full MOQT protocol instrumentation above the raw transport layer.
