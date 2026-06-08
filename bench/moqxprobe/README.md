# MOQXProbe

This directory is a standalone Mix project for transport performance and limit
research. It depends on the root `moqx` project by path and exercises it through
public APIs. It is not part of normal library tests, ExUnit integration tests,
or the root commit-time correctness checklist.

The harness answers one question:

> How far can a real QUIC path be pushed before it degrades or fails, and how
> much of that path can `moqx` fill under stream, datagram, and mixed
> MOQT-shaped load?

Local runs are useful only for calibration. They can prove the harness works
and estimate local BEAM, `quicer`, and host overhead, but they are not evidence
about real network behavior.

## Non-Goals

- Full MOQT draft-14 session behavior.
- Full MOQ Lite behavior.
- Pass/fail performance thresholds.
- Production deployment automation or long-lived cloud environments.
- Public relay performance baselines.
- New benchmark-only dependencies in the library dependency graph.

## Evidence Tiers

Benchmark results must identify their evidence tier.

| Tier | Name | Use |
| --- | --- | --- |
| `loopback_calibration` | Same host or loopback | Validate harness behavior and local overhead only. |
| `same_region_pair` | Two controlled servers in one region | Low-RTT real path evidence. |
| `cross_region_pair` | Two controlled servers in different regions | Higher-RTT, BDP-sensitive evidence. |
| `edge_to_server` | Developer/home/edge path to controlled server | Asymmetric or real-user-path evidence. |
| `public_relay_interop` | Public relays or public namespaces | Interop/smoke probing only, not controlled baselines. |

Only controlled server paths should be used for benchmark claims. Public relays
can be useful for compatibility checks, but relay load, namespace behavior, and
network path are outside this harness' control.

## Path Description

Every benchmark run must describe the path under test. A path is the network
relationship between sender and receiver, not just the hostnames.

Required path metadata:

- `evidence_tier`
- `path_id`
- `client.host_id`
- `server.host_id`
- `client.provider`
- `server.provider`
- `client.region`
- `server.region`
- `client.instance_class`
- `server.instance_class`
- `client.os`
- `server.os`
- `client.kernel`
- `server.kernel`
- `client.cpu_model`
- `server.cpu_model`
- `client.memory_bytes`
- `server.memory_bytes`
- `client.nic_or_network_class`
- `server.nic_or_network_class`

Unknown values should be recorded as `null`, not omitted.

## Benchmark Matrix

The harness supports these benchmark families. Individual tools may implement
them incrementally, but they must use the shared output schema.

### Path Baseline

Use `iperf3` to establish raw host/path capacity:

- TCP throughput baseline.
- UDP offered-rate sweep.
- UDP loss and jitter at each offered rate.

`iperf3` is not a QUIC or MOQT benchmark. It is the path ceiling used to
interpret QUIC results.

The repo-owned runtime command is:

```bash
moqxprobe iperf3-baseline --server <host-or-ip>
```

The local Mix wrapper is:

```bash
cd bench/moqxprobe
mix moqx.transport.iperf3_baseline --server <host-or-ip>
```

It expects the caller to provide an `iperf3` server endpoint. For local smoke
validation only, it can start a temporary loopback server:

```bash
cd bench/moqxprobe
mix moqx.transport.iperf3_baseline \
  --server 127.0.0.1 \
  --port 55201 \
  --local-server \
  --tcp-duration 1 \
  --udp-duration 1 \
  --udp-bitrates 1M
```

For remote controlled paths, start `iperf3 --server` on the server host
yourself and pass the public or private endpoint explicitly. The task does not
provision infrastructure, start Terraform, or assume loopback.

Each `iperf3` step is killed after its requested duration plus
`--timeout-margin-seconds` (default: 5). For example, a TCP step with
`--tcp-duration 10` uses a 15 second process timeout. Timed-out steps still emit
valid JSONL with `limits.first_break_symptom=step_timeout` and
`errors.close_reason=timeout`.

Path metadata can be supplied as either a JSON file path or an inline JSON
object:

```bash
moqxprobe iperf3-baseline \
  --server 203.0.113.10 \
  --path-json '{"evidence_tier":"edge_to_server","path_id":"example-public-ipv4","client":{"host_id":"client","provider":null,"region":null,"instance_class":null,"os":null,"kernel":null,"cpu_model":null,"memory_bytes":null,"nic_or_network_class":"public_ipv4"},"server":{"host_id":"server","provider":null,"region":null,"instance_class":null,"os":null,"kernel":null,"cpu_model":null,"memory_bytes":null,"nic_or_network_class":"public_ipv4"}}'
```

The same option accepts Terraform `output -json <name>` values, including
wrappers shaped as `{"value": ...}` or `{"path": ...}`.

### Self-Pair Calibration

Run `MOQX.Transport.Quicer` client and listener on the same host or loopback.

This measures local overhead:

- BEAM scheduling and mailbox behavior.
- `quicer` adapter overhead.
- host CPU and memory behavior.
- harness measurement overhead.

Self-pair results must be labeled `loopback_calibration`.

The repo-owned runtime command is:

```bash
moqxprobe self-pair --profile draft_14
```

The local Mix wrapper is:

```bash
cd bench/moqxprobe
mix moqx.transport.self_pair --profile draft_14
```

It accepts `draft_14` and `moq_lite_04` profiles. The `draft_14` profile runs
handshake/first-byte, stream-pressure, and datagram-pressure steps; the
`moq_lite_04` profile runs handshake/first-byte and stream-pressure steps
because that profile disables QUIC DATAGRAM.

For quick local validation, keep counts deliberately small and write JSONL to a
temporary path:

```bash
cd bench/moqxprobe
mix moqx.transport.self_pair \
  --profile draft_14 \
  --stream-count 1 \
  --payload-count 2 \
  --datagram-count 2 \
  --output /private/tmp/moqx-quicer-self-pair-smoke.jsonl
```

By default the task creates short-lived localhost certificates under ignored
`.tmp/transport-bench-certs/`. Pass `--certfile`, `--keyfile`, and
`--cacertfile` together to use existing certificates explicitly.

### Sender Admission

Run the local sender-only DATAGRAM admission microbenchmark when the question is
whether the local sender can call into the transport stack fast enough before
network delivery, peer echo, or listener behavior enter the measurement.

```bash
cd bench/moqxprobe
mix moqx.transport.sender_admission \
  --mode moqx \
  --mode quicer \
  --schedule paced \
  --tick-ms 1 \
  --datagram-size 1180 \
  --datagram-count 96000 \
  --burst-size 32 \
  --target-rate 32000 \
  --output /private/tmp/moqx-sender-admission.jsonl
```

The command opens a local quicer pair, hands the server-side connection to a
dedicated sink process, reuses one fixed DATAGRAM payload, and records per-burst
admission timing. Before sending, it waits for the client-side DATAGRAM-ready
event and rejects payload sizes above the negotiated local maximum. It emits
`sender-admission-v1` JSONL, not `transport-bench-v1`, because this is a local
microbenchmark for the load generator and transport sender path. Treat the
output as loopback calibration only. `--burst-size` represents the number of
DATAGRAM admission calls the future paced sink would need to pay in one tick;
`--target-rate` defines the per-burst time budget, for example 32 DATAGRAMs in
1 ms at 32k pps. Use `--schedule burst` to measure raw admission capacity and
`--schedule paced --tick-ms 1` to measure the absolute-timer burst pacer shape.

### Measure

Run the selected reference QUIC implementation on controlled server paths:

- `moqx` client to reference server.
- reference client to `moqx` listener.
- reference client to reference server where practical.

Reference-to-reference results help separate path/tool limits from `moqx`
limits.

The first selected reference implementation is the repo-owned Go tool
`bench/quicprobe`. Its `client --json` mode emits `quicprobe-v1` JSON for a
single reference client run. That output is an implementation-specific
reference measurement, not the canonical benchmark schema; `moqxprobe`
commands are responsible for converting reference measurements into
`transport-bench-v1` JSONL records. The `server` mode is an explicit peer
process; it supports stream echo/drain and QUIC DATAGRAM echo.

```bash
go run ./bench/quicprobe server --addr :4433 \
  --cert .tmp/integration-certs/server.pem \
  --key .tmp/integration-certs/server-key.pem \
  --alpn moqx-test

go run ./bench/quicprobe client --addr 127.0.0.1:4433 \
  --ca .tmp/integration-certs/ca.pem \
  --alpn moqx-test \
  --json \
  --stream-direction bidirectional \
  --stream-count 4 \
  --payload-size 1200 \
  --payload-count 100
```

For unidirectional stream pressure, set
`--stream-direction unidirectional`. Bidirectional pressure reports bytes sent,
bytes echoed back, first-byte latency, aggregate goodput, and stream latency
percentiles. Unidirectional pressure reports bytes sent and write-side stream
latency; it has no echo bytes or first-byte latency.

For `moqx-client-to-reference-server` bidirectional stream pressure, canonical
records include `stream-pressure-diagnostics-v1`. These diagnostics separate
send admission from send completion and echo receive: accepted payload sends,
completed/cancelled/pending send completions, active send duration, active echo
receive duration, stream data/FIN/send-completion/close/ignored event counts,
per-stream completion status, and sender mailbox depth/peak/sample points.
Human reports include a compact diagnostics row for records that carry these
signals.

The MOQX-client stream-pressure path also exposes benchmark-only diagnostic
knobs for performance isolation:

- `--stream-send-window N` controls max in-flight async sends per stream.
- `--stream-event-batch-size N` drains up to `N` ready transport events after
  each blocking receive before waiting again.
- `--stream-diagnostics-sampling event|final` keeps the default fixed-interval
  mailbox sampler while the stream-pressure step runs, or records only the
  final stream/process snapshot.

These knobs are not protocol semantics. Use them to distinguish benchmark
event-pump overhead, event granularity, and transport/NIF behavior while
preserving send admission and completion accounting.

MOQX-client stream pressure uses `MOQXProbe.Traffic.StreamSender`. The sender
composes a bounded Flow payload producer with a single GenStage stream sink:

```text
payload descriptors -> bounded stream sink -> MOQX.Transport.send_stream/4
                                      ^ send-completion feedback
```

The sink is the only process that calls `MOQX.Transport.send_stream/4` for pure
stream pressure. It owns per-stream admission windows, FIN placement on the
final payload for each stream, bounded producer demand, and stream-sender
telemetry under `[:moqx, :transport_bench, :stream_sender, ...]`.
Bidirectional pressure keeps echo validation, timeout/failure classification,
and report assembly in the existing receive-event loop; send-completion events
feed back into the sink to reopen per-stream windows.

Paced MOQX-client DATAGRAM pressure uses `MOQXProbe.Traffic.DatagramSender`.
The sender composes a bounded Flow payload producer with a single GenStage
paced sink:

```text
payload descriptors -> bounded DATAGRAM sink -> MOQX.Transport.send_datagram/3
```

The sink is the only process that calls `MOQX.Transport.send_datagram/3` for
the connection. It uses 1 ms absolute monotonic deadlines, sends small bounded
bursts, and records scheduler lag or capped catch-up ticks instead of hiding
tool slippage behind unbounded bursts. Payload production is demand-bound by
the sink queue. Sequence/timestamp payloads encode the timestamp at the paced
send point; fixed payloads and prefilled payload rings are prepared before the
timed send loop, so the hot path does not allocate or read random bytes.

Benchmark-owned telemetry is emitted under
`[:moqx, :transport_bench, :datagram_sender, ...]`:

- `[:run, :start]` and `[:run, :stop]` for sender lifecycle.
- `[:demand, :ask]` and `[:backlog, :change]` for producer demand and queue
  depth.
- `[:tick, :stop]` for lag, due count, sent count, capped ticks, tool-limited
  ticks, burst duration, send errors, and queue depth.
- `[:send, :error]` for burst send-error summaries.

Use `--datagram-diagnostics summary` for the normal low-overhead pressure path.
Use `--datagram-diagnostics full` only when diagnosing a lower-rate
reproduction or when the observer effect is acceptable. `--quicer-setting
pacing_enabled=0` disables MsQuic pacing for this paced load-generator path so
the benchmark's own offered-rate scheduler controls timing. Pass
`--quicer-setting KEY=VALUE` to override or add whitelisted quicer connection
settings for an experiment.

Use `sender-admission` only for lower-level BEAM-to-NIF admission calibration.
It answers whether local DATAGRAM admission can keep up when pacing is already
solved; `measure --workload datagram_pressure --datagram-rate ...`
is the benchmark path for peer-facing QUIC DATAGRAM pressure evidence.

For datagram pressure, use `--workload datagram_pressure`. By default the
workload sends a burst of `--datagram-count` fixed-size QUIC DATAGRAM frames.
For a fixed-rate step, set both `--datagram-rate` and `--duration-seconds`; the
offered datagram count becomes `rate * duration`, and the record distinguishes
target offered rate from actual send and delivered rates. Datagram pressure
records offered datagrams, locally accepted sends, echoed datagrams, delivery
ratio, drops, and datagram latency percentiles. Delivery below
`--delivery-threshold` maps to
`limits.first_break_symptom=datagram_delivery_loss`.
For paced steps, actual send rate is part of the measurement contract:
`offered_rate_ratio` is actual send rate divided by target rate, and
`offered_rate_valid=false` means the load generator missed
`--offered-rate-tolerance` and the result is tool evidence, not network
capacity evidence. Paced DATAGRAM records also expose active send duration,
target send duration, scheduled send span, and send-loop pacing lag fields so
operator reports can distinguish sender slippage from network or receiver
loss. The reference-client JSON also records synchronous `SendDatagram` call
duration percentiles, `p999`, max, total call time, and slow-call counts. In
quic-go this isolates time spent copying/enqueueing into the library's bounded
DATAGRAM send queue from time spent waiting for the absolute pacing deadline;
high pacing lag with low `SendDatagram` call time points at
timer/scheduler/send-loop slippage, while high call time points at quic-go
DATAGRAM queue backpressure.

For `moqx-client-to-reference-server` DATAGRAM runs, the canonical benchmark
record includes
`moqx-client-datagram-diagnostics-v1` with accepted/received/missing counts,
receive-loop event counts, active send/receive/observation durations, receive
stop reason, paced send schedule lag, send-loop overrun, DATAGRAM send-call
timing, payload encode timing, outer send-call timing, wrapper/telemetry
overhead, residual loop overhead, and the client receiver mailbox
depth/peak/samples. These records also include a bounded `diagnostics.cadence`
trace. Cadence samples record elapsed time, accepted/received totals and
deltas, duplicate/invalid counts, delivery gap to locally accepted sends, and,
for paced workloads, the expected datagram count at the target offered rate.
Use this trace to distinguish sender admission, payload allocation,
wrapper/telemetry overhead, pacing/scheduler lag, receiver drain cadence, and
peer delivery loss without changing the stable `transport-bench-v1` top-level
fields.

Controlled ARM MOQX/quicer DATAGRAM measurements have used
`--datagram-size 1192` as a near-limit payload size, but this is not universal:
the sender-admission loopback harness observed a 1187-byte negotiated local
maximum on 2026-05-29. Prefer the negotiated maximum when the harness exposes
one; otherwise keep 1192 as the current real-path near-limit default.
Controlled ARM evidence from 2026-05-26 showed the current MOQX send path
accepts 1192-byte DATAGRAM payloads and rejects 1193 bytes and above with
`:invalid_parameter`. `bench/quicprobe` reference-to-reference runs can still
use larger payloads, such as 1200 bytes, to establish the reference path
ceiling.

```bash
go run ./bench/quicprobe client --addr 127.0.0.1:4433 \
  --ca .tmp/integration-certs/ca.pem \
  --alpn moqx-test \
  --json \
  --workload datagram_pressure \
  --datagram-size 1200 \
  --datagram-count 1000
```

```bash
go run ./bench/quicprobe client --addr 127.0.0.1:4433 \
  --ca .tmp/integration-certs/ca.pem \
  --alpn moqx-test \
  --json \
  --workload datagram_pressure \
  --datagram-size 1200 \
  --datagram-rate 1000 \
  --duration-seconds 10 \
  --offered-rate-tolerance 0.95
```

The canonical benchmark wrapper supports two caller-side topologies:
reference-to-reference and MOQX-client-to-reference-server.

```bash
moqxprobe measure \
  --topology reference-client-to-reference-server \
  --server 127.0.0.1 \
  --port 4433 \
  --ca .tmp/integration-certs/ca.pem \
  --quicprobe-command /path/to/quicprobe \
  --stream-direction bidirectional \
  --stream-count 4 \
  --payload-size 1200 \
  --payload-count 100 \
  --output bench/moqxprobe/results/measure.jsonl

moqxprobe measure \
  --topology moqx-client-to-reference-server \
  --server 127.0.0.1 \
  --port 4433 \
  --ca .tmp/integration-certs/ca.pem \
  --servername localhost \
  --stream-direction bidirectional \
  --stream-count 4 \
  --payload-size 1200 \
  --payload-count 100 \
  --output bench/moqxprobe/results/moqx-client-reference.jsonl

```

Use the same two topologies for datagram pressure by replacing the stream
options with an explicit datagram workload.

For mixed MOQT-shaped pressure, use `--workload mixed_moqt_shaped`. The first
mixed workload is intentionally transport-shaped rather than a full MOQT
session: one low-rate bidirectional control stream plus object-like
unidirectional streams. The object stream pressure uses `--stream-count`,
`--payload-size`, and `--payload-count`; the control trickle uses
`--control-payload-size`, `--control-message-count`, and `--control-rate`.
The record reports `control_trickle_bps` and `control_latency_p99_ms`
separately from aggregate stream/object goodput. For the MOQX-client topology,
the mixed workload uses bounded object-stream send windows and drains async
send-completion events while the control stream is active, so object pressure
does not silently accumulate in the caller mailbox.

```bash
moqxprobe measure \
  --topology moqx-client-to-reference-server \
  --workload mixed_moqt_shaped \
  --server 127.0.0.1 \
  --port 4433 \
  --ca .tmp/integration-certs/ca.pem \
  --servername localhost \
  --stream-count 4 \
  --payload-size 1200 \
  --payload-count 100 \
  --control-payload-size 64 \
  --control-message-count 100 \
  --control-rate 10 \
  --output bench/moqxprobe/results/moqx-client-reference-mixed.jsonl
```

The measurement command does not start the peer server. For reference server
topologies, start `bench/quicprobe server` explicitly on the chosen endpoint
first. Then run `measure` from the client side. The wrapper emits
`transport-bench-v1` JSONL. The MOQX-client topology opens all requested
streams, schedules payload rounds across those streams, and records
`stream_scheduling=concurrent` for pure stream pressure and
`stream_scheduling=mixed_control_bidi_object_uni` for mixed pressure. Stream
sends are accepted asynchronously by `MOQX.Transport.send_stream/4`; send
completion is reported later as a transport event and is not peer-delivery
proof. Mixed-pressure diagnostics include object send-completion counts,
pending completion counts, drained event counts, current sender mailbox depth,
peak observed sender mailbox depth, and zero-wait completion-drain events
observed after the workload success condition has been met.

### Pressure Patterns

Tools should model transport-level pressure patterns before full protocol
semantics exist:

- stream pressure: one stream, many streams, bidirectional streams,
  unidirectional streams;
- datagram pressure: fixed-size datagrams in burst mode first, then at stepped
  offered rates once pacing/ramp support exists;
- mixed MOQT-shaped pressure: a low-rate control stream plus object-like
  unidirectional streams and/or datagrams.

Mixed pressure is not a full MOQT session. It is a transport pattern shaped
like MOQT data-plane pressure.

## Protocol Profiles

Benchmark tools should accept a protocol-like profile argument.

Initial profiles:

- `draft_14`
  - ALPN: `moq-00` unless overridden.
  - QUIC DATAGRAM: enabled.
  - Workloads may use one control-like bidirectional stream plus
    unidirectional object streams and/or datagrams.
- `moq_lite_04`
  - ALPN: `moq-lite-04` unless overridden.
  - QUIC DATAGRAM: disabled.
  - Workloads may use many bidirectional transaction-like streams and
    unidirectional group-like streams.

Profiles are transport fixtures. They do not implement full protocol rules, and
the transport layer does not enforce protocol-specific stream counts or message
types.

## Ramp Methodology

Benchmarks that push capacity should use a ramp rather than a single run.

Each ramp should have:

- fixed-duration warmup;
- stepped offered load;
- fixed steady-state sample window for each step;
- cooldown between steps where needed;
- explicit stop conditions.

Recommended initial defaults:

- warmup: 5 seconds;
- step duration: 30 seconds;
- cooldown: 5 seconds;
- minimum steps: 3;
- repeated runs per step: 3 when feasible.

Scripts may use different values, but they must record them in the run
metadata.

## Stop Conditions

A ramp should stop when any configured stop condition is reached.

Common stop conditions:

- connection closed unexpectedly;
- protocol error;
- stream send failure;
- stream stalls past configured timeout;
- datagram delivery ratio falls below threshold;
- p95 or p99 latency exceeds threshold;
- throughput plateaus while offered load increases;
- sender mailbox depth grows without recovery;
- receiver mailbox depth grows without recovery;
- CPU is saturated for sustained interval;
- memory grows past configured limit;
- control traffic is delayed behind media/object traffic.

Stop thresholds are tool parameters. #08 defines the shape, not universal
pass/fail thresholds.

## "Breaks Apart" Symptoms

Benchmark reports should make degradation and failure explicit. A path or run is
breaking apart when one or more of these symptoms appear:

- QUIC connection close;
- protocol error;
- send failure;
- stream stall;
- datagram delivery collapse;
- latency explosion;
- throughput plateau despite higher offered load;
- mailbox growth without recovery;
- CPU saturation;
- memory saturation;
- control traffic delayed behind media/object traffic.

Tools should record the first observed symptom and any final close/error
reason.

## Output Format

Benchmark tools must emit machine-readable JSON or JSONL. JSONL is preferred
for ramps because each step can be one record.

All records must include:

- `schema_version`
- `record_type`
- `run`
- `path`
- `software`
- `profile`
- `workload`
- `methodology`
- `metrics`
- `limits`
- `errors`

Use `null` for unknown values and keep units in field names.

The benchmark project includes a human-readable report command for JSONL
artifacts:

```bash
moqxprobe report /path/to/run.jsonl
moqxprobe report /path/to/run.jsonl --strict
```

The local Mix wrapper is:

```bash
cd bench/moqxprobe
mix moqx.transport.report /path/to/run.jsonl
mix moqx.transport.report /path/to/run.jsonl --strict
```

The report command is a reader and validator only. JSONL remains the canonical
benchmark artifact.

Measurement plumbing is defined in
[`ADR-0005`](../../docs/adr/0005-telemetry-backed-transport-benchmark-measurement.md).
In short: `transport-bench-v1` JSONL remains the stable output contract, while
transport and benchmark measurements may be collected through `:telemetry`,
`telemetry_metrics` declarations, and benchmark-owned collectors.
The shared JSONL/path metadata validation code lives in `bench/ledger`; this
CLI owns producing and reporting the measurements, not the reusable specs.
Self-pair calibration and MOQX-client stream, DATAGRAM, and mixed pressure use
the same `MOQXProbe.TransportTelemetryCollector` path for transport timings,
event counts, and bounded mailbox samples.

### Record Types

- `run_summary`: one record for a complete run.
- `step_summary`: one record for a ramp step.
- `sample`: optional periodic sample record.

### Run Metadata

Required `run` fields:

```json
{
  "schema_version": "transport-bench-v1",
  "record_type": "run_summary",
  "run": {
    "run_id": "2026-05-18T12-00-00Z-host-a-host-b-draft14",
    "started_at": "2026-05-18T12:00:00Z",
    "finished_at": "2026-05-18T12:05:00Z",
    "git_sha": "abcdef0",
    "script": "moqxprobe example",
    "script_version": "v1",
    "command": "moqxprobe example ...",
    "notes": null
  }
}
```

Required `software` fields:

```json
{
  "software": {
    "elixir_version": "1.18.0",
    "otp_version": "27.0",
    "moqx_version": "0.7.1",
    "quicer_version": null,
    "msquic_version": null,
    "reference_implementation": "quic-go",
    "reference_version": null
  }
}
```

Required `profile` fields:

```json
{
  "profile": {
    "name": "draft_14",
    "alpn": "moq-00",
    "datagrams": true,
    "congestion_control": null,
    "pacing": null,
    "settings": {}
  }
}
```

Required `path` fields:

```json
{
  "path": {
    "evidence_tier": "same_region_pair",
    "path_id": "provider-a-region-1-small-to-small",
    "client": {
      "host_id": "client-1",
      "provider": "provider-a",
      "region": "region-1",
      "instance_class": "small",
      "os": "linux",
      "kernel": null,
      "cpu_model": null,
      "memory_bytes": null,
      "nic_or_network_class": null
    },
    "server": {
      "host_id": "server-1",
      "provider": "provider-a",
      "region": "region-1",
      "instance_class": "small",
      "os": "linux",
      "kernel": null,
      "cpu_model": null,
      "memory_bytes": null,
      "nic_or_network_class": null
    }
  }
}
```

### Workload Metadata

Required `workload` fields:

```json
{
  "workload": {
    "family": "stream_pressure",
    "direction": "client_to_server",
    "stream_direction": "unidirectional",
    "stream_count": 32,
    "payload_size_bytes": 1200,
    "payloads_per_second": null,
    "offered_load_bps": 100000000,
    "datagram_size_bytes": null,
    "datagrams_per_second": null,
    "control_trickle_bps": null
  }
}
```

Allowed `workload.family` values:

- `path_baseline`
- `self_pair_calibration`
- `stream_pressure`
- `datagram_pressure`
- `mixed_moqt_shaped`
- `measurement`
- `public_relay_interop`

### Methodology Metadata

Required `methodology` fields:

```json
{
  "methodology": {
    "warmup_seconds": 5,
    "step_seconds": 30,
    "cooldown_seconds": 5,
    "step_index": 1,
    "step_count": 5,
    "repetition_index": 1,
    "repetition_count": 3,
    "stop_conditions": [
      "connection_closed",
      "latency_p99_ms_gt_1000",
      "datagram_delivery_ratio_lt_0.95"
    ]
  }
}
```

### Metrics

Required `metrics` fields:

```json
{
  "metrics": {
    "handshake_latency_ms": 12.4,
    "first_byte_latency_ms": 18.1,
    "offered_load_bps": 100000000,
    "goodput_bps": 91000000,
    "send_rate_packets_per_second": 8200,
    "send_rate_datagrams_per_second": null,
    "delivered_datagrams_per_second": null,
    "datagram_delivery_ratio": null,
    "datagram_drop_count": null,
    "datagram_late_count": null,
    "stream_count": 32,
    "payload_size_bytes": 1200,
    "latency_p50_ms": 21.2,
    "latency_p95_ms": 44.7,
    "latency_p99_ms": 88.9,
    "sender_cpu_percent": null,
    "receiver_cpu_percent": null,
    "sender_memory_bytes": null,
    "receiver_memory_bytes": null,
    "sender_mailbox_depth": null,
    "receiver_mailbox_depth": null,
    "send_backpressure_ms": null,
    "stream_stall_count": 0,
    "control_latency_p99_ms": null
  }
}
```

Required `limits` and `errors` fields:

```json
{
  "limits": {
    "first_break_symptom": null,
    "stopped_by": null,
    "connection_closed": false,
    "protocol_error": false,
    "throughput_plateau": false,
    "latency_explosion": false,
    "mailbox_growth_without_recovery": false,
    "cpu_saturation": false,
    "memory_saturation": false,
    "control_traffic_delayed": false
  },
  "errors": {
    "close_reason": null,
    "error_code": null,
    "message": null
  }
}
```

## Units

Use these units unless a field name states otherwise:

- time: milliseconds for metrics, seconds for methodology durations;
- throughput and offered load: bits per second;
- rates: events per second;
- memory: bytes;
- CPU: percentage of one host's total CPU capacity;
- timestamps: ISO 8601 UTC strings.

## Tool Conventions

Elixir benchmark tools live in this nested Mix project. The runtime CLI is
`moqxprobe`; local Mix tasks under `moqx.transport.*` are wrappers
over the same command modules. Legacy `.exs` paths under
`bench/moqxprobe/scripts/` are compatibility delegates into the nested project.
The project depends on root `moqx` by path so the library dependency graph stays
free of benchmark-only code. Non-Elixir tools are allowed when they are the
benchmark subject or selected reference tool.

Tools must:

- accept caller-provided endpoints;
- avoid mutating `Application` env as a test seam;
- avoid adding benchmark-only dependencies to the root `mix.exs`;
- print JSON or JSONL to stdout;
- write optional artifacts under `bench/moqxprobe/results/` or a caller-provided
  output directory;
- include enough command parameters in output to reproduce the run.

Tools should not:

- start cloud/server infrastructure implicitly;
- start Docker implicitly unless the tool is explicitly a local calibration
  helper;
- treat public relay results as controlled performance baselines;
- hide failed runs by omitting output.

## Release Packaging

The benchmark project can be packaged as an Elixir release on the local
machine:

```bash
cd bench/moqxprobe
MIX_ENV=prod mix clean
MIX_ENV=prod mix release --overwrite
_build/prod/rel/moqxprobe_runtime/bin/moqxprobe help
```

The user-facing release wrapper is:

```text
bin/moqxprobe
```

It delegates to the release management script internally and boots the full
release once per command with a short-lived release node name, so operators do
not need to call release internals manually. Release artifacts are
target-specific because the project includes the `quicer` NIF; build the release on the same
OS/architecture/ABI as the remote benchmark node or in a matching container.

### Burrito Packaging Spike

`moqxprobe` also has an experimental Burrito release target. Burrito packages
the BEAM release plus ERTS into a single self-extracting binary and reads CLI
arguments through `Burrito.Util.Args.argv/0`.

Build one target explicitly:

```bash
just bench-transport-build-burrito darwin_arm64
```

The `just` recipe delegates to the root mise task:

```bash
mise run bench:moqxprobe:burrito --target darwin_arm64
```

On macOS, Burrito still requires Zig 0.15.2, but the official Zig tarball used
by mise's normal Zig backend does not link correctly on macOS 26/Xcode 26. The
mise task therefore checks for Homebrew's patched `zig@0.15` formula and puts
that binary first in `PATH` only for the Burrito build. Install or verify it
with:

```bash
mise run tools:zig:install-patched
mise run tools:zig:doctor
```

The current target aliases are:

- `darwin_arm64`
- `linux_arm64`
- `linux_x86_64`

The host-local Burrito task is useful for smoke-testing wrapper behavior on the
current machine. It is not sufficient for Linux deployment from macOS because
the release payload would still contain the locally compiled `quicer` NIF.

For Hetzner ARM nodes, build the Linux/ARM64 artifact with Docker:

```bash
just bench-transport-build-release linux_arm64
```

The artifact path is:

```text
bench/moqxprobe/build/artifacts/moqxprobe-<version>-<git>-linux-arm64.tar.gz
```

The Docker build embeds the same git SHA in the benchmark release, so records
emitted by the remote CLI can be tied back to the artifact that produced them.

The Docker build uses `elixir:1.19.5-otp-28` by default and can be overridden:

```bash
ELIXIR_IMAGE=elixir:1.19.5-otp-28 just bench-transport-build-release linux_arm64
```

Use the same target names as the other transport-bench artifacts:

```bash
just bench-transport-release-artifact-rel linux_arm64
just bench-transport-release-artifact-rel linux_x86_64
```

If the target architecture cannot be built reliably from the workstation, build
the Mix release natively on an already-provisioned benchmark node and fetch the
artifact back locally:

```bash
just bench-transport-build-release-remote-role <run-id> client linux_x86_64
```

The native remote build uploads a `git archive HEAD` source snapshot over SSH,
checks that the remote machine architecture matches the requested target, builds
the normal glibc-compatible Mix release on that host, and stores the fetched
artifact under the same local `build/artifacts/` naming convention:

```text
bench/moqxprobe/build/artifacts/moqxprobe-<version>-<git>-linux-x86_64.tar.gz
```

For Burrito packaging experiments, build inside the target Linux Docker image so
native dependencies are compiled for the same OS/architecture as the remote
node:

```bash
just bench-transport-build-burrito-release linux_arm64
```

The artifact is still a deploy-compatible tarball containing
`bin/moqxprobe`, but that executable is the Burrito self-extracting binary:

```text
bench/moqxprobe/build/artifacts/moqxprobe-burrito-<version>-<git>-linux-arm64.tar.gz
```

Keep Burrito as experimental for Linux `moqxprobe` while the project depends on
the `quicer` NIF. The canonical remote deployment path is the Mix release above;
the Burrito runtime can use a different libc ABI than the native quicer build,
which can make the extracted NIF fail at runtime even when compilation succeeds.

The Dockerfile stages dependency resolution and `mix deps.compile quicer`
before copying application source, so the expensive `libquicer_nif.so` layer is
reused unless the target, OTP image, lockfiles, or native dependency inputs
change. The recipe accepts `linux_arm64` and `linux_x86_64`; the x86_64 target
uses an amd64 Docker builder, so build it on native amd64 or on a builder where
the amd64 OTP image can start reliably.

Build the matching `bench/quicprobe` reference peer artifact:

```bash
just bench-transport-build-quicprobe linux_arm64
```

The default artifact path is:

```text
bench/moqxprobe/build/artifacts/quicprobe-<git>-linux-arm64.tar.gz
```

`quicprobe` is packaged separately from the Elixir release so reference peer
deployment stays explicit and the benchmark release does not need a Go runtime.
The default build cross-compiles locally with mise-managed Go and runs
`go test ./...` before producing the tarball. Supported native build targets
are `linux_arm64`, `linux_x86_64`, `darwin_arm64`, and `darwin_x86_64`.
The Docker fallback is Linux-only:
`just bench-transport-build-quicprobe-docker <target>`.

Deploy a built artifact to the Terraform `client` and `server` roles in
parallel:

```bash
just bench-transport-deploy-release linux_arm64
```

Deploy a built Burrito artifact to the same roles only when intentionally
validating the experimental Burrito path:

```bash
just bench-transport-deploy-burrito linux_arm64
```

Deploy the built `quicprobe` artifact to the same roles:

```bash
just bench-transport-deploy-quicprobe linux_arm64
```

`quicprobe` deploy targets are Linux-only because Terraform benchmark nodes are
Linux hosts.

The deploy recipe reads the current run id from
`bench/moqxprobe/.run/current`, resolves public SSH targets from Terraform
outputs, and writes one log per target under
`bench/moqxprobe/results/<run_id>/`. Each role is a separate deploy unit; the
top-level deploy fails if either role fails.

For manual one-off targets, use the lower-level target recipe. The artifact
path is relative to `bench/moqxprobe/` unless absolute:

```bash
just bench-transport-deploy-target \
  root@203.0.113.10 \
  20260520T134420Z-smoke \
  build/artifacts/moqxprobe-0.1.0-<git>-linux-arm64.tar.gz
```

Deployment copies the tarball, extracts it under
`/opt/moqx-bench/moqxprobe/releases/<artifact-name>/`, updates the
`current` symlink, and runs:

```bash
/opt/moqx-bench/moqxprobe/current/bin/moqxprobe help
```

`quicprobe` deployment copies the tarball, extracts it under
`/opt/moqx-bench/quicprobe/releases/<artifact-name>/`, updates the `current`
symlink, and verifies that the binary starts:

```bash
/opt/moqx-bench/quicprobe/current/bin/quicprobe 2>&1 | grep -q usage:
```

The deploy target does not provision infrastructure or run benchmark traffic.
The role-based recipe reads Terraform outputs only to resolve the already
provisioned `client` and `server` public SSH targets.

## Result Storage

Generated results should not be committed by default. If a result is important
enough to keep, store a summarized artifact or checked-in fixture intentionally.

Suggested local paths:

```text
bench/moqxprobe/results/
bench/moqxprobe/results/<run_id>.json
bench/moqxprobe/results/<run_id>.jsonl
```

## Ephemeral Infrastructure

Controlled server-pair benchmarks may use repo-owned Terraform under
`bench/infra/` when the infrastructure is short-lived, explicit, and
destroyed by the caller after the run. Provisioning is separate from benchmark
tools: benchmark tasks must accept endpoints and must not call Terraform
themselves.

The first supported target is Hetzner Cloud:

```text
bench/infra/hetzner/
```

That setup creates two benchmark endpoints with profile `.tfvars` files for
ARM CAX and x86 CCX variants. It keeps cloud-init deliberately small on Ubuntu:
base build tools, `iperf3`, Go from the official Linux archive, and
Erlang/Elixir from the official Elixir install script. It does not install
development-only version managers, clone this repo, or start any benchmark
process.

Firewall policy for the Hetzner setup:

- allow the operator CIDR to reach all TCP ports, all UDP ports, and ICMP;
- allow peer-to-peer benchmark traffic between the two endpoints;
- allow private-network traffic when the private network is enabled;
- deny other inbound traffic;
- allow outbound TCP, UDP, and ICMP.

Terraform outputs include path metadata for public IPv4 and private-network
runs. Benchmark tools should merge those outputs with live host inventory and
run-specific metrics.

Before using private-network path metadata, run:

```bash
just bench-transport-private-check
```

The check proves that both nodes have their configured private IPs ready and
that the client can reach the server private IP over ICMP and TCP. Treat private
path benchmark results as invalid if this readiness check has not passed for
the same Terraform run.

## Implementation Order

The intended issue order is:

1. Define this contract (#08).
2. Add ephemeral controlled-server infrastructure (#22).
3. Add raw path baseline tools (#09).
4. Add self-pair calibration tools (#10).
5. Select the first reference QUIC implementation and topology (#11).
6. Add Docker release build/deploy tooling (#23).
7. Add real-path reference benchmark tools (#12).
