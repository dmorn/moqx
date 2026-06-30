# MOQXProbe

`bench/moqxprobe` is a standalone Mix project for transport benchmark clients.
It depends on the root `moqx` library by path and exercises public transport
APIs. It is not part of the root library test suite.

The active goal is caller-side performance work: compare process architectures
that publish over QUIC streams or DATAGRAMs, first in isolation and then
against a simple `quicprobe` target.

## Measurement contract

How to read these numbers — what each layer measures, the closed-loop vs
open-loop distinction, metric naming rules, lifecycle windows, and confidence
tiers — is defined in
[ADR-0009: Layered benchmark evidence contract](../../docs/adr/0009-layered-benchmark-evidence-contract.md)
(handler discipline and the telemetry event bus come from ADR-0005). In short:
Benchee `ips` is closed-loop invocation throughput, not wire bandwidth or
latency-under-load; every reported metric carries its source layer, window, and
confidence tier; and naked `bandwidth`/`goodput` and stream `pkts/s` are
forbidden.

## Current Loop

The benchmark loop is target-driven:

- `target=fake` isolates the benchmark client process model from QUIC, network,
  TLS, and peer behavior.
- `target=quicprobe` connects to a local or remote `bench/quicprobe` server
  using explicit flags.
- `iperf3` is a preflight/path baseline. It is not a Benchee job and is not
  mixed into hot-path timing.

Local loopback and fake-target results are calibration only. Real network
claims need a real target path and an `iperf3` baseline from the same client to
the same server.

Delivery-aware runs keep timing and delivery validity separate. The measured
Benchee function sends the workload and returns a small run receipt. When
evidence is enabled, an unmeasured post-run hook finalizes the connection,
reads target evidence, stores it through a reusable
`MOQXProbe.Benchee.EvidenceCollector`, and emits sidecar validity data.
Polling `quicprobe` or any other target for final evidence must not happen
inside the measured function.

Delivery profiles are MOQT-shaped:

- `draft14_object_stream` sends object bytes on unidirectional streams and
  requires completed receiver evidence.
- `draft14_object_datagram` sends object payloads as QUIC DATAGRAMs and
  validates server receive counts from a `quicprobe` target running
  `--datagram-semantics drain`.

The evidence collector uses target adapters:

- `MOQXProbe.Benchee.Adapters.FakeTransport` reads explicit fake transport
  state/counters after timing.
- `MOQXProbe.Benchee.Adapters.Quicprobe` reads the always-on quicprobe
  evidence HTTP API after timing, with local JSONL as a fallback artifact path.
  For real `quicprobe` targets, it also acquires an exclusive experiment lease
  before the suite starts.

The Quicprobe adapter captures both the final aggregates and the receiver
delivery shape over time. Lifecycle offsets surface as observed metrics
(`first_stream_byte_at_ms`, `last_stream_byte_at_ms`, `first_datagram_at_ms`,
`last_datagram_at_ms`), and the raw interval bins are preserved under the
evidence `metadata.receiver_interval` (bin width plus per-window
bytes/datagrams/events). The sidecar stays backward compatible: against an
older quicprobe build without interval fields, `receiver_interval` is `nil` and
no interval metrics are added. The bins are raw counts; deriving `*_bps`
belongs to a later report slice (ADR-0009).

## Install

```bash
cd bench/moqxprobe
mix deps.get
```

## Stream Clients

Run the stream-client matrix against the fake transport:

```bash
cd bench/moqxprobe
mix run bench/stream_clients.exs -- \
  --target fake \
  --stream-count 32 \
  --payload-count 1000 \
  --payload-size 1180 \
  --stream-send-window 16 \
  --benchee-time 3
```

Save a Benchee suite for later comparison:

```bash
mix run bench/stream_clients.exs -- \
  --target fake \
  --implementation sender_shards \
  --sender-shard-count 4 \
  --flow-stages 1 \
  --input flow-generated \
  --save results/sender-shards.benchee
```

Stream sender implementations are intentionally kept as named benchmark
artifacts. `moqxprobe` is a small client-architecture lab: new process models
are added as explicit implementations, compared with Benchee, and kept as
trace even after one implementation becomes the preferred baseline.

Current stream implementations:

| implementation | status | purpose |
| --- | --- | --- |
| `context_owner` | control | One Flow-fed GenStage sink owns all stream queues and completion state; useful as the simple global-queue baseline. |
| `stream_owner` | historical | One Flow-fed worker per stream; useful for measuring per-stream process ownership overhead. |
| `sender_shards` | historical | Bounded Flow-fed worker set; each shard owns a subset of streams and `--sender-shard-count` tunes the process-model shape. |
| `flow_partitions` | current best | Flow source with `GenStage.PartitionDispatcher` at the final consumer boundary; one GenStage sink owns each shard and stops after source EOF plus send-completion drain. |

All stream sender implementations consume the same Flow-produced payload path
so process-model comparisons are apples-to-apples. Local sender summaries and
delivery-evidence metadata include the implementation label, status,
architecture, and tested bottleneck so saved suites remain self-describing.

`flow_partitions` uses explicit per-partition source EOF control events. Source
EOF only means no more payload events will arrive for that partition; QUIC stream
FIN remains part of the final payload event for each stream. A partition sink
stops normally only after source EOF, empty local queues, zero in-flight sends,
and all expected send completions.

The stream-client matrix exposes tuning knobs independently:

- `--sender-shard-count` controls sender worker count for `sender_shards` and
  partition sink count for `flow_partitions`.
- `--flow-stages` is currently constrained to `1` for ordered stream workloads;
  increasing source stages can reorder payload events for one stream and send
  FIN before earlier payloads.
- `--min-demand`, `--max-demand`, and `--max-queue-depth` control GenStage
  demand/backlog.
- `--stream-send-window` controls per-stream backend send-completion credit.

The best local fake calibration seen so far for `flow_partitions` used
`--sender-shard-count 8 --min-demand 128 --max-demand 256 --max-queue-depth 1024`
with `--flow-stages 1`.

Run against a `quicprobe` target:

```bash
mix run bench/stream_clients.exs -- \
  --target quicprobe \
  --host <target-host-or-ip> \
  --quic-port <quic-port> \
  --iperf-port <iperf-port> \
  --ca <ca.pem> \
  --servername <cert-name> \
  --alpn moqx-test \
  --stream-count 32 \
  --payload-count 1000
```

Enable delivery evidence for the fake target:

```bash
mix run bench/stream_clients.exs -- \
  --target fake \
  --implementation stream_owner \
  --input flow-generated \
  --evidence-output results/fake-evidence.jsonl
```

Enable delivery evidence for `quicprobe`:

```bash
mix run bench/stream_clients.exs -- \
  --target quicprobe \
  --host <target-host-or-ip> \
  --quic-port <quic-port> \
  --ca <ca.pem> \
  --servername <cert-name> \
  --evidence-output results/quicprobe-evidence.jsonl
```

Evidence mode requires `--benchee-parallel 1` so each invocation can be matched
to one receiver evidence record. For `quicprobe`, the post-run hook waits an
unmeasured close grace before closing the connection; override it with
`--evidence-close-grace-ms` when a path needs a longer drain window.
The quicprobe evidence API defaults to `http://<host>:55434`; override it with
`--quicprobe-evidence-url` or use `--quicprobe-evidence-path` for a local JSONL
fallback.

Do not run parallel benchmark suites against the same `quicprobe`. The
receiver evidence stream is ordered by target-local connection sequence, so two
clients sharing one target would corrupt attribution. `moqxprobe` enforces this
by acquiring an exclusive experiment lease from the quicprobe HTTP API before
the Benchee suite starts. If the target is already leased, the run fails before
opening QUIC connections.

The script exposes setup through flags, not environment variables or
`Application` configuration. Use `--help` for the full option list.

## Open-loop paced stream sender

`bench/paced_stream.exs` is the **open-loop** measurement mode of
[ADR-0009](../../docs/adr/0009-layered-benchmark-evidence-contract.md). It is a
standalone script, deliberately separate from the closed-loop Benchee scripts
above. Do not compare its numbers with Benchee `ips`: the two modes answer
different questions and ADR-0009 forbids cross-mode comparison.

The difference is the harness shape:

- **Closed loop (Benchee, `stream_clients.exs`/`datagram_clients.exs`)** calls a
  job, waits for it to return, then calls it again. It measures per-invocation
  service time. The offered rate is whatever the job can self-throttle to, so
  backpressure is silently absorbed and the run can coordinated-omit the stalls.
- **Open loop (`paced_stream.exs`)** offers payload intents on a fixed
  **wall-clock** schedule regardless of completion. It never throttles the
  offered rate to match what the transport accepts — that is the whole point.
  Backpressure shows up as growing backlog and tick lag instead of a slower
  offered rate.

Run it against the fake target:

```bash
cd bench/moqxprobe
mix run bench/paced_stream.exs -- \
  --target fake \
  --offered-rate 50000 \
  --tick-ms 1 \
  --duration-ms 3000 \
  --stream-count 32 \
  --payload-size 1180 \
  --paced-output results/paced.jsonl
```

Run it against a `quicprobe` target with delivery evidence:

```bash
mix run bench/paced_stream.exs -- \
  --target quicprobe \
  --host <target-host-or-ip> \
  --quic-port <quic-port> \
  --ca <ca.pem> \
  --servername <cert-name> \
  --tier remote_quic_no_wire \
  --offered-rate 50000 \
  --duration-ms 5000 \
  --paced-output results/paced.jsonl \
  --evidence-output results/paced-evidence.jsonl
```

### Flags

Schedule (the open-loop core):

- `--offered-rate N` — schedule rate. Payload events per second in the default
  `--rate-mode payload-events`, or bytes per second in `--rate-mode bytes`. The
  cumulative scheduled intent count is `floor(offered_rate * elapsed / 1000)`
  (divided by `--payload-size` in bytes mode), so integer truncation in one tick
  is repaid by the next rather than drifting.
- `--rate-mode payload-events|bytes` — schedule unit (default
  `payload-events`).
- `--tick-ms N` — wall-clock tick interval (default `1`).
- `--duration-ms N` — schedule window length (default `3000`).
- `--stream-count N` — unidirectional streams the intents are spread over
  round-robin (default `32`).
- `--payload-size BYTES` — bytes per payload intent (default `1180`).
- `--drain-ms N` — post-window settle/drain budget for in-flight send
  completions (default `500`); out of band, never throttles the schedule.

Coordinated-omission detection (detect only):

- `--backlog-threshold N` — trip the flag when backlog (offered minus accepted)
  exceeds N (default `4096`).
- `--sustained-lag-ms N` — a tick is "lagging" when its `tick_lag_ms` exceeds N
  (default `5`).
- `--sustained-lag-ticks N` — trip the flag after N consecutive lagging ticks
  (default `10`).

Output and tier:

- `--paced-output PATH` — write the `moqxprobe-paced-v1` JSONL sidecar.
- `--tier TIER` — evidence tier metadata: `loopback_quic` (default),
  `remote_quic_no_wire`, or `remote_quic_with_wire`.

It also reuses the closed-loop scripts' delivery-evidence flags
(`--evidence-output`, `--quicprobe-evidence-url`/`-path`, `--evidence-*-ms`),
the out-of-band host sampler (`--host-sample-ms` / `--host-samples-output`,
monitoring the `paced_sender` role), and the run-metadata flags (`--git-sha`,
`--tailscale-path-mode`, `--server-stats-path`). Use `--help` for the full list.

### Coordinated omission

When the offered rate cannot be sustained — backlog grows past
`--backlog-threshold`, or tick lag stays above `--sustained-lag-ms` for
`--sustained-lag-ticks` consecutive ticks — the run sets a `coordinated_omission`
flag (latched for the rest of the run, with a recorded cause) and prints a
warning. This means a naive latency reading would omit the stalls, so the
system would look healthier than it is.

This slice is **detect only**: it records the *fact* of coordinated omission so
a corrected reading can be built later. It does **not** compute a corrected
latency histogram or corrected percentiles — that is deferred to issue 56
(`.scratch/transport-layer-foundation/issues/56-add-coordinated-omission-corrected-latency-histogram.md`).
The schedule math and offered/accepted/backlog/lag
accounting live in the pure, unit-tested modules `MOQXProbe.OpenLoop.Pacer` and
`MOQXProbe.OpenLoop.Accounting`; the script is a thin transport/IO shell around
them.

### Sidecar shape

`--paced-output` writes a `moqxprobe-paced-v1` JSONL sidecar: a header line, one
row per tick, and a final summary row. Metric names follow the ADR-0009 rule
(source layer + numerator + denominator/window); counts are raw, windows are
explicit, and there is no naked `bandwidth`/`goodput` and no stream `pkts/s`.

Header (`record_type: "header"`): `schema_version` (`moqxprobe-paced-v1`),
`mode: "open_loop"`, `tier`, `target`, `rate_mode`, `offered_rate` and
`offered_rate_unit`, `tick_ms`, `duration_ms`, `stream_count`, `payload_size`,
the detection thresholds, run metadata, and
`coordinated_omission_corrected_latency: "deferred_to_issue_56"`.

Each tick (`record_type: "tick"`, `window: "sender_active"`,
`source_layer: "sender"`): `tick_index`, `scheduled_at_ms`/`now_ms`/`elapsed_ms`,
`scheduled_total`, `offered_payload_events`,
`accepted_payload_events_sender_active`, `send_admission_error_count`,
`backlog_payload_events`, `tick_lag_ms`, the running totals, and the current
`coordinated_omission` flag.

Summary (`record_type: "summary"`): `tick_count`,
`offered_payload_events_total`, `accepted_payload_events_sender_active_total`,
`send_admission_error_count`, `send_completions_drain_total` and
`send_cancellations_drain_total` (the post-window tail-drain counters credited
by `Accounting.record_settlement/2`), `backlog_payload_events`,
`max_backlog_payload_events`, `max_tick_lag_ms`, a `tick_lag_ms` distribution
summary, and the final `coordinated_omission` flag plus
`coordinated_omission_cause`.

The per-second sender-active views (e.g.
`offered_payload_events_per_second`,
`accepted_payload_events_sender_active`) are derived in the report layer from
these raw counts and the explicit `duration_ms` window; the sidecar keeps raw
counts only, per the ADR-0009 evidence-layer rule.

Delivery evidence (`--evidence-output`) is collected **out of band**, after the
paced send window, through the same `EvidenceCollector` and quicprobe adapter as
the closed-loop scripts — the paced send loop never blocks on evidence polling.
Against `quicprobe` the run still proves delivery, but as a **lower bound**, not
exact equality: open loop deliberately offers faster than the transport can
deliver, so at window close some admitted sends are still in flight and the
receiver keeps draining after the schedule ends. The check is therefore
`receiver stream bytes >= accepted payload events * --payload-size` (an
`{:at_least, …}` expectation); the receiver may legitimately report more once
the tail drains, and asserting exact equality would mark a valid run invalid.
The tail itself is made explicit: `settle/3` drains the post-window send
completions/cancellations and records them through
`Accounting.record_settlement/2` as `send_completions_drain_total` /
`send_cancellations_drain_total` in the summary, rather than discarding them.

## Host and BEAM samples

`MOQXProbe.HostSampler` is the out-of-band sampler for the "Host and BEAM
samples" evidence layer in
[ADR-0009](../../docs/adr/0009-layered-benchmark-evidence-contract.md). It
periodically records BEAM/host saturation evidence during a run and writes a
`host-samples` JSONL sidecar, mirroring the `--evidence-output` pattern.

Enable it with two explicit flags (both required together):

```bash
mix run bench/stream_clients.exs -- \
  --target fake \
  --implementation flow_partitions \
  --input flow-generated \
  --host-sample-ms 20 \
  --host-samples-output results/host-samples.jsonl
```

- `--host-sample-ms N` — sampling interval in milliseconds. Default `0` disables
  sampling. A positive value requires `--host-samples-output`.
- `--host-samples-output PATH` — JSONL sidecar destination.

Like delivery evidence, host sampling requires `--benchee-parallel 1`.

### Out-of-band guarantee

The sampler runs in its **own process**. It is never invoked from inside a
`:telemetry` handler and never from inside the timed Benchee function
(ADR-0009 observer-effect rule, ADR-0005 handler discipline). The script starts
it before the measured suite and stops it after; sampling spans the run but all
of its work — VM statistics, the `:scheduler.utilization/1` delta, and a bounded
`Process.info/2` read per monitored role — happens in the sampler process, not
in the hot path. On start it enables the `:scheduler_wall_time` system flag and
restores the prior value on stop. It never shells out on the sampling cadence.

All inputs are passed explicitly as `start_link/1` arguments (interval, output
path, monitored `{label, pid}` roles). There is no `Application` configuration.

### Sidecar shape

The sidecar is JSONL with a header line followed by one object per sample. Raw
values only (ADR-0009): utilization fractions in `[0, 1]`, raw run-queue lengths
and mailbox depths, the sampler interval on every row, and stable string role
labels — never raw pids, and no derived `bandwidth`/`goodput`.

Header (`record_type: "header"`): `schema_version`
(`moqxprobe-host-samples-v1`), `sample_interval_ms`, `schedulers`,
`schedulers_online`, `otp_release`, and the list of monitored `roles` (labels).

Each sample (`record_type: "host_sample"`):

- `sample_index`, `offset_ms` (monotonic offset from sampler start),
  `sample_interval_ms`;
- `scheduler_utilization_fraction`, `scheduler_utilization_weighted_fraction`,
  and `per_scheduler_utilization_fraction` (per-scheduler fractions);
  utilization is populated from the first emitted sample (the baseline
  snapshot is captured when the sampler starts), and is only `null` when the
  VM has no scheduler_wall_time data;
- `total_run_queue_length`, `per_run_queue_length`, `run_queue`,
  `total_active_tasks`, `schedulers_online`, `process_count`;
- `roles`: one entry per monitored process with the stable `role` label,
  `alive?`, and `message_queue_len`/`reductions`/`memory_bytes` (all `null` and
  `alive?: false` when the monitored pid is dead).

The stream client monitors the Benchee suite driver process under the
`benchee_suite_driver` role label.

## DATAGRAM Clients

Run the Flow-produced, GenStage-paced DATAGRAM client against the fake target:

```bash
mix run bench/datagram_clients.exs -- \
  --target fake \
  --datagram-count 10000 \
  --datagram-rate 30000 \
  --datagram-size 1180 \
  --benchee-time 3
```

Run it against a `quicprobe` target with receiver evidence:

```bash
mix run bench/datagram_clients.exs -- \
  --target quicprobe \
  --host <target-host-or-ip> \
  --quic-port <quic-port> \
  --ca <ca.pem> \
  --servername <cert-name> \
  --datagram-count 1000 \
  --datagram-rate 30000 \
  --evidence-output results/quicprobe-datagram-evidence.jsonl
```

The DATAGRAM script uses the same evidence output format as the stream script.
Remote sidecars include target host, QUIC/iperf ports, CA/server name, git SHA,
optional iperf3 summary files, optional Tailscale path mode, optional server
stats path, the selected profile, and a compact local sender summary.

## Target Preflight

Before interpreting QUIC numbers for a real target, run a short `iperf3`
baseline from the benchmark client host:

```bash
iperf3 --client <target-host-or-ip> --port <iperf-port> --time 5 --json
iperf3 --client <target-host-or-ip> --port <iperf-port> --udp --bitrate 100M --time 5 --json
```

Keep those outputs as sidecar metadata for the benchmark run. They provide the
raw path ceiling and basic loss/jitter context; they are not QUIC measurements.

## Reference Peer

`bench/quicprobe` is the reference peer. It can run as a local process or as a
persistent service on a VM:

```bash
go run ../quicprobe server \
  --addr :4433 \
  --cert <server.pem> \
  --key <server-key.pem> \
  --alpn moqx-test \
  --datagram-semantics drain \
  --evidence-bin-ms 100 \
  --stats-output <run-evidence.jsonl>
```

The server emits one compact `server_run_evidence` JSON record per completed
connection to stdout and to `--stats-output` when configured. The record is
receiver-side evidence, not a client benchmark result: bidirectional streams
are echoed, unidirectional streams are drained and counted, and DATAGRAMs are
handled according to `--datagram-semantics`.

Beyond the final aggregates, each record also carries the receiver delivery
*shape* over time (ADR-0009 receiver-evidence layer). It reports lifecycle
offsets (`first_stream_byte_at_ms` / `last_stream_byte_at_ms` and
`first_datagram_at_ms` / `last_datagram_at_ms`) and a sequence of fixed-width
`interval_bins`. Each bin records its `start_offset_ms` and the raw
`stream_bytes`, `datagram_bytes`, `datagrams`, `stream_payload_events`, and
`streams_completed` accumulated in that window. The window width is
configurable via `--evidence-bin-ms` (default 100) and echoed back as
`interval_bin_width_ms`. Bins are raw counts only: per ADR-0009 the evidence
layer never derives a rate, so deriving `*_bps` is left to the report layer.
Use `drain` for publish-only `moqxprobe` DATAGRAM benchmarks. Use `echo` only
for round-trip/reference-client DATAGRAM checks where the client expects echoed
DATAGRAMs back.
The server also always exposes an evidence and experiment-lease HTTP API on
`--evidence-http-addr`, defaulting to `:55434`:

- `GET /healthz`
- `GET /evidence/latest`
- `GET /evidence/runs?after_sequence=N`
- `GET /experiment/lease`
- `POST /experiment/lease/acquire`
- `POST /experiment/lease/release`

Every `server_run_evidence` record emitted while a lease is active includes
`experiment_lease_owner` and `experiment_lease_token`. `moqxprobe` includes
the token in the receiver-evidence match criteria, so a run does not accept a
record from another owned suite.

For remote VMs, keep `iperf3` and `quicprobe` running under systemd and deploy
new `quicprobe` artifacts with the root `just` recipes. VM setup and service
operation details live in the `exe-dev-vm-ops` skill.

## Artifact Policy

The active artifact story is intentionally small:

- Benchee saved suites or console output.
- Delivery-evidence sidecars collected after timed invocations.
- Optional sidecar metadata for target, git SHA, command flags, `iperf3`
  baseline, telemetry summaries, packet captures, and flamegraphs.
- Optional `quicprobe` server run evidence when the target writes it.

The previous `transport-bench-v1` JSONL report pipeline, shared ledger project,
remote `probed` daemon, release-deploy scripts, and Terraform lab are legacy
history. Do not add new benchmark work to those paths.

## Development Gate

When changing this project, run:

```bash
cd bench/moqxprobe
mix format --check-formatted
mix test
mix credo --strict
```

For docs-only changes, the Elixir gate is not required.
