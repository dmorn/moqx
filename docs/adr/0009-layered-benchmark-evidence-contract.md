# ADR-0009: Layered benchmark evidence contract

- Status: Accepted
- Date: 2026-06-30

Implements the contract requested in
`.scratch/transport-layer-foundation/issues/54-add-layered-benchmark-evidence-contract.md`.
Builds on ADR-0005 (telemetry event bus and handler discipline) and ADR-0008
(functional `Conn`/`Stream` ownership and the send-completion-as-credit model).

## Context

The transport benchmark loop exists to validate transport implementations and
client topologies against measurements: `bench/moqxprobe` compares caller-side
client implementations with Benchee, fake targets isolate process-model
effects, `quicprobe` targets give receiver-side delivery evidence, and `iperf3`
gives a path baseline. The plumbing is already disciplined: timed functions
return receipts, receiver evidence is collected in unmeasured post-run hooks,
and telemetry handlers follow ADR-0005's bounded-handler rules.

The problem is interpretation, not plumbing. The current output makes it too
easy to collapse several different questions into one ambiguous number:

- Benchee `ips` is invocation throughput, not wire bandwidth. The invocation
  may include connect, stream creation, the sender loop, and local
  send-completion draining.
- Receiver evidence validates final aggregate counts. It proves delivery, but
  not delivery *shape* over time.
- Manually derived "Gbps" divides known payload bytes by a chosen duration
  without naming the denominator, so it can be mistaken for steady-state
  bandwidth, receiver bandwidth, path utilization, or wire rate.
- Averaging over a whole invocation hides bursts, drain lag, receiver stalls,
  and backpressure: all of these can produce the same final bytes/time ratio.

The root cause has a name. **Benchee is a closed-loop harness.** It calls the
job, waits for it to return, then calls it again. That measures *service time*
(how long one invocation takes) and *invocation rate* (`ips`). It cannot
measure "at offered rate R, what goodput does the receiver see and what is the
latency distribution," because the offered rate is whatever the job can
self-throttle to. Reading a closed-loop service-time number as if it were an
open-loop throughput/latency number is why measurements feel untrustworthy.

This also exposes us to **coordinated omission** (Gil Tene's term): when the
transport applies backpressure and the sender slows its offered load, a
closed-loop benchmark records only the sends that happened and silently omits
the demand that was held back. The stalls we most want to see are exactly what
drops out of the sample, so the system always looks healthier than it is.

## Decision

Adopt a layered evidence contract with two explicitly labelled measurement
modes, a metric naming rule, lifecycle windows, and confidence tiers. Every
benchmark number must declare which mode and tier it came from, and numbers
from different modes must never be compared directly.

### Two measurement modes

**Closed-loop (Benchee).** Answers: which client implementation/topology has
lower per-invocation service time and overhead. The engine is Benchee; the
unit is one invocation. Valid for `fake` and `loopback_quic` tiers. This mode
ranks implementations (for example `flow_partitions` vs `sender_shards`). It is
**not** a bandwidth, receiver-throughput, or latency-under-load claim.

**Open-loop (paced sender).** Answers: at a target offered rate R, what
receiver goodput, latency distribution, and resource saturation result, and is
the sender coordinated-omitting. The engine is a fixed-schedule paced sender
that offers load regardless of completion, recording offered-vs-accepted rate
so backpressure is visible rather than absorbed. This mode produces real-path
claims and is the only mode valid for `remote_quic_*` saturation conclusions.

A run records its mode. A derived metric inherits its mode. Reports must not
place a closed-loop `ips` and an open-loop goodput in the same comparison.

### Metric naming rule

Every derived metric name must make four things explicit:

```text
source_layer + numerator + denominator/window + (tier in metadata)
```

Examples:

- `client_payload_goodput_total_bps`
- `client_payload_goodput_sender_active_bps`
- `receiver_payload_goodput_active_bps`
- `receiver_payload_goodput_interval_p95_bps`
- `stream_payload_events_per_second`
- `datagrams_received_per_second`
- `path_baseline_tcp_bps`

Forbidden names:

- naked `bandwidth`;
- naked `goodput`;
- `pkts/s` or `packets_per_second` unless the source is a packet capture or a
  QUIC-stack packet counter;
- stream send/write counts reported as packets — they are `payload_events`,
  `write_events`, or `send_admissions`;
- DATAGRAM counts reported as packets — they are `datagrams`.

Reports must refuse or warn on a forbidden name rather than render it.

### Evidence layers

A run bundle models these layers, each answering a distinct question. Each
layer is collected by the mechanism noted; none may run inside a timed Benchee
function or inside a hot-path telemetry handler (ADR-0005).

- **Experiment lifecycle** — a stable run id and manifest tying every artifact
  together (see Run Manifest). Owned by the script.
- **Benchee invocation timing** — invocation latency distribution, `ips`,
  statistical spread between implementations. Closed-loop only.
- **Sender/app telemetry** — offered payload events, send admissions and
  errors, send-completion credits, per-stream/shard in-flight counts, queue
  depth/demand/backlog, tick lag and burst shape for paced clients, sender-side
  interval bins. Answers whether the client can feed the transport without
  collapsing. Cheap counters per ADR-0005.
- **Transport/NIF telemetry** — the stable `MOQX.Transport` events from
  ADR-0005 (stream send, DATAGRAM send, receive-event call durations and
  results, send completions/cancellations), plus counts of slow calls above a
  configured threshold near the 1 ms scheduler-risk boundary. Answers whether
  transport/`quicer` admission and completion handling is the bottleneck. Not
  peer-delivery evidence.
- **Receiver evidence** — `quicprobe` aggregate truth (first/last byte and
  DATAGRAM timestamps, bytes received, streams accepted/completed, DATAGRAMs
  received, receive errors) plus interval bins for bytes/DATAGRAMs/streams over
  time. Collected outside the timed function; the post-run wait must not
  contaminate sender timing.
- **Path baseline** — `iperf3` TCP/UDP as a preflight, not a Benchee job.
  Compared against QUIC-derived receiver metrics only when target and path are
  explicit, and the report states which baseline (TCP, or UDP at configured
  bitrate), loss/jitter/retransmits, and whether the path was local, loopback,
  direct remote, or relay-like.
- **Host and BEAM samples** — low-frequency out-of-band samples taken by a
  dedicated sampler process: scheduler utilization / run-queue lengths, sender-
  role mailbox lengths, reductions/memory for known roles, GC where practical,
  host CPU/memory and NIC counters where practical. A sampler, never a
  per-event handler.
- **Wire evidence** — optional, forensic packet capture as a sidecar,
  summarized separately and clearly labelled packet-capture-derived. The only
  acceptable source for `packets_per_second` until a QUIC-stack packet counter
  exists.
- **Flame graphs** — diagnostic artifacts, not standard metrics. Linked from
  the bundle with the profiled process/command noted; not required for ordinary
  summaries.

### Lifecycle windows

Metrics distinguish time windows instead of averaging over the whole run. A
derived metric carries its window in the name or metadata.

- `setup` — connect, handshake, stream creation, initial target setup;
- `sender_active` — first send attempt to last accepted send or last local
  send completion, depending on the metric;
- `receiver_active` — first to last receiver byte/DATAGRAM;
- `drain` — sender done to receiver complete;
- `total_invocation` — the Benchee measured invocation;
- `post_run_evidence` — unmeasured cleanup and evidence collection;
- `steady_state` — optional middle window excluding configured warmup and
  tail/drain when the workload is long enough.

### Confidence tiers

Every run and report carries an evidence tier, used to qualify conclusions:

- `fake` — process-model only; no QUIC or network claim. Justifies OTP/process
  changes, not path claims. Closed-loop.
- `loopback_quic` — local QUIC calibration; no real-network claim. Closed-loop
  or open-loop.
- `remote_quic_no_wire` — real target with receiver evidence and an iperf3
  baseline, no packet capture.
- `remote_quic_with_wire` — real target plus host samples and a packet-capture
  summary.
- `forensic` — diagnostic bundle with flame graphs and deeper host/wire
  evidence.

### Run manifest and artifact layout

One run produces a bundle under `bench/moqxprobe/results/<run-id>/` with a
manifest that links every artifact and makes missing optional artifacts
explicit. The manifest records: command and arguments, git SHA, project/tool
versions, target host/ports, client implementation, workload/profile, target
type (`fake`, `loopback_quic`, `remote_quic`), measurement mode, evidence tier,
sidecar paths, and clock/source notes. Suggested sidecars (subset allowed):
`manifest.json`, `benchee.json`, `delivery-evidence.jsonl`,
`sender-telemetry.jsonl`, `receiver-intervals.jsonl`, `host-samples.jsonl`,
`iperf3-tcp.json`, `iperf3-udp.json`, `capture.pcapng`, `capture-summary.json`,
`flamegraph.svg`, `report.md`. Sidecars are additive evidence linked by run id,
never replacements for the manifest.

This stays within the current target-based loop. It does not revive Terraform,
`probed`, `bench/ledger`, release-deploy orchestration, or `transport-bench-v1`
as active requirements.

## Consequences

Positive:

- A number can be read with the right confidence: "client process model is the
  bottleneck" (fake), "transport/NIF admission is the bottleneck", "receiver is
  draining late", "the path is constrained", "the workload is bursty", or "the
  measurement itself is too intrusive."
- Closed-loop and open-loop questions stop being conflated, so optimization
  work targets the real bottleneck instead of ranking by an ambiguous average.
- Coordinated omission becomes detectable (offered-vs-accepted) and then
  avoidable (open-loop mode).
- Evidence layers reuse ADR-0005 events and handler discipline rather than
  inventing new hot-path work.

Tradeoffs:

- Two modes mean reports must carry mode/tier metadata and refuse cross-mode
  comparison; this is enforcement work in the report layer.
- The open-loop paced sender is a new component, distinct from the Benchee
  engine.

## Non-goals

- A generic dashboard, Prometheus/StatsD export, or a persistent daemon.
- Mandatory packet capture or flame graphs for normal runs.
- Receiver evidence inside the timed Benchee function.
- Treating local/fake/loopback results as real-network claims.
- High-cardinality labels (payload sequence number, raw stream id, raw
  connection handle, per-event peer address, exception text, payload bytes) —
  ADR-0005 cardinality rules still apply.
- `Application` environment as mutable benchmark configuration; runs are
  configured by explicit flags.
