# Transport Benchmark Harness

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
moqx-transport-bench iperf3-baseline --server <host-or-ip>
```

The local Mix wrapper is:

```bash
cd bench/transport
mix moqx.transport.iperf3_baseline --server <host-or-ip>
```

It expects the caller to provide an `iperf3` server endpoint. For local smoke
validation only, it can start a temporary loopback server:

```bash
cd bench/transport
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
moqx-transport-bench iperf3-baseline \
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
moqx-transport-bench self-pair --profile draft_14
```

The local Mix wrapper is:

```bash
cd bench/transport
mix moqx.transport.self_pair --profile draft_14
```

It accepts `draft_14` and `moq_lite_04` profiles. The `draft_14` profile runs
handshake/first-byte, stream-pressure, and datagram-pressure steps; the
`moq_lite_04` profile runs handshake/first-byte and stream-pressure steps
because that profile disables QUIC DATAGRAM.

For quick local validation, keep counts deliberately small and write JSONL to a
temporary path:

```bash
cd bench/transport
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

### Reference Comparison

Run the selected reference QUIC implementation on controlled server paths:

- `moqx` client to reference server.
- reference client to `moqx` listener.
- reference client to reference server where practical.

Reference-to-reference results help separate path/tool limits from `moqx`
limits.

The first selected reference implementation is the repo-owned Go tool
`tools/quicprobe`. Its `client --json` mode emits `quicprobe-v1` JSON for a
single reference client run. That output is an implementation-specific
reference measurement, not the canonical benchmark schema; `moqx-transport-bench`
commands are responsible for converting reference measurements into
`transport-bench-v1` JSONL records. The `server` mode is an explicit peer
process; it supports stream echo/drain and QUIC DATAGRAM echo.

```bash
go run ./tools/quicprobe server --addr :4433 \
  --cert .tmp/integration-certs/server.pem \
  --key .tmp/integration-certs/server-key.pem \
  --alpn moqx-test

go run ./tools/quicprobe client --addr 127.0.0.1:4433 \
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

For burst-mode datagram pressure, use `--workload datagram_pressure`.
Datagram pressure sends fixed-size QUIC DATAGRAM frames, records offered
datagrams, locally accepted sends, echoed datagrams, delivery ratio, drops, and
datagram latency percentiles, then maps delivery loss to
`limits.first_break_symptom=datagram_delivery_loss`. This first reference
comparison slice is intentionally burst-only; rate-stepped offered-load
datagram ramps remain future work.

```bash
go run ./tools/quicprobe client --addr 127.0.0.1:4433 \
  --ca .tmp/integration-certs/ca.pem \
  --alpn moqx-test \
  --json \
  --workload datagram_pressure \
  --datagram-size 1200 \
  --datagram-count 1000
```

The canonical benchmark wrapper supports reference-to-reference,
MOQX-client-to-reference-server, and reference-client-to-MOQX-listener
topologies:

```bash
moqx-transport-bench reference-comparison \
  --topology reference-client-to-reference-server \
  --server 127.0.0.1 \
  --port 4433 \
  --ca .tmp/integration-certs/ca.pem \
  --quicprobe-command /path/to/quicprobe \
  --stream-direction bidirectional \
  --stream-count 4 \
  --payload-size 1200 \
  --payload-count 100 \
  --output bench/transport/results/reference-comparison.jsonl

moqx-transport-bench reference-comparison \
  --topology moqx-client-to-reference-server \
  --server 127.0.0.1 \
  --port 4433 \
  --ca .tmp/integration-certs/ca.pem \
  --servername localhost \
  --stream-direction bidirectional \
  --stream-count 4 \
  --payload-size 1200 \
  --payload-count 100 \
  --output bench/transport/results/moqx-client-reference.jsonl

moqx-transport-bench moqx-listener \
  --host 0.0.0.0 \
  --port 4433 \
  --certfile .tmp/integration-certs/server.pem \
  --keyfile .tmp/integration-certs/server-key.pem \
  --stream-count 4 \
  --payload-size 1200 \
  --payload-count 100

moqx-transport-bench reference-comparison \
  --topology reference-client-to-moqx-listener \
  --server 127.0.0.1 \
  --port 4433 \
  --ca .tmp/integration-certs/ca.pem \
  --quicprobe-command /path/to/quicprobe \
  --stream-direction bidirectional \
  --stream-count 4 \
  --payload-size 1200 \
  --payload-count 100 \
  --output bench/transport/results/reference-client-moqx-listener.jsonl
```

Use the same topologies for datagram pressure by replacing the stream options
with an explicit datagram workload. For example, start a MOQX listener peer:

```bash
moqx-transport-bench moqx-listener \
  --host 0.0.0.0 \
  --port 4433 \
  --certfile .tmp/integration-certs/server.pem \
  --keyfile .tmp/integration-certs/server-key.pem \
  --workload datagram_pressure \
  --datagram-size 1200 \
  --datagram-count 1000
```

Then run the reference client topology against it:

```bash
moqx-transport-bench reference-comparison \
  --topology reference-client-to-moqx-listener \
  --server 127.0.0.1 \
  --port 4433 \
  --ca .tmp/integration-certs/ca.pem \
  --quicprobe-command /path/to/quicprobe \
  --workload datagram_pressure \
  --datagram-size 1200 \
  --datagram-count 1000 \
  --output bench/transport/results/reference-client-moqx-listener-datagrams.jsonl
```

The measurement command does not start the peer server. For reference server
topologies, start `tools/quicprobe server` explicitly on the chosen endpoint
first. For reference-client-to-MOQX-listener runs, start
`moqx-transport-bench moqx-listener` explicitly on the server endpoint; it
serves one connection by default and then exits. Then run
`reference-comparison` from the client side. The wrapper emits
`transport-bench-v1` JSONL. The MOQX-client topology opens all requested
streams, schedules payload rounds across those streams, and records
`stream_scheduling=concurrent`. Stream sends are accepted asynchronously by
`MOQX.Transport.send_stream/4`; send completion is reported later as a
transport event and is not peer-delivery proof.

`moqx-transport-bench moqx-listener` is a correctness and interop peer, not yet
a high-rate performance peer. Its stream-pressure path currently accepts the
expected streams up front, then serves them in stream-id order. That is useful
for contract smokes, but heavier listener-side performance claims need a
dedicated concurrent serving path.

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
moqx-transport-bench report /path/to/run.jsonl
moqx-transport-bench report /path/to/run.jsonl --strict
```

The local Mix wrapper is:

```bash
cd bench/transport
mix moqx.transport.report /path/to/run.jsonl
mix moqx.transport.report /path/to/run.jsonl --strict
```

The report command is a reader and validator only. JSONL remains the canonical
benchmark artifact.

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
    "script": "moqx-transport-bench example",
    "script_version": "v1",
    "command": "moqx-transport-bench example ...",
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
- `reference_comparison`
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
`moqx-transport-bench`; local Mix tasks under `moqx.transport.*` are wrappers
over the same command modules. Legacy `.exs` paths under
`bench/transport/scripts/` are compatibility delegates into the nested project.
The project depends on root `moqx` by path so the library dependency graph stays
free of benchmark-only code. Non-Elixir tools are allowed when they are the
benchmark subject or selected reference tool.

Tools must:

- accept caller-provided endpoints;
- avoid mutating `Application` env as a test seam;
- avoid adding benchmark-only dependencies to the root `mix.exs`;
- print JSON or JSONL to stdout;
- write optional artifacts under `bench/transport/results/` or a caller-provided
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
cd bench/transport
MIX_ENV=prod mix release --overwrite
_build/prod/rel/moqx_transport_bench/bin/moqx-transport-bench help
```

The user-facing release wrapper is:

```text
bin/moqx-transport-bench
```

It delegates to the release management script internally and boots the full
release once per command with a short-lived release node name, so operators do
not need to call release internals manually. Release artifacts are
target-specific because the project includes the `quicer` NIF; build the release on the same
OS/architecture/ABI as the remote benchmark node or in a matching container.

For Hetzner ARM nodes, build the Linux/ARM64 artifact with Docker:

```bash
just bench-transport-build-release
```

The default artifact path is:

```text
bench/transport/build/artifacts/moqx-transport-bench-<version>-<git>-linux-arm64.tar.gz
```

The Docker build embeds the same git SHA in the benchmark release, so records
emitted by the remote CLI can be tied back to the artifact that produced them.

The Docker build uses `elixir:1.19.5-otp-28` by default and can be overridden:

```bash
ELIXIR_IMAGE=elixir:1.19.5-otp-28 TARGET_ARCH=arm64 \
  just bench-transport-build-release
```

Build the matching Linux/ARM64 `tools/quicprobe` reference peer artifact:

```bash
just bench-transport-build-quicprobe
```

The default artifact path is:

```text
bench/transport/build/artifacts/quicprobe-<git>-linux-arm64.tar.gz
```

`quicprobe` is packaged separately from the Elixir release so reference peer
deployment stays explicit and the benchmark release does not need a Go runtime.
The Docker build runs `go test ./...` before producing the tarball.

Deploy a built artifact to the Terraform `client` and `server` roles in
parallel:

```bash
just bench-transport-deploy
```

Deploy the built `quicprobe` artifact to the same roles:

```bash
just bench-transport-deploy-quicprobe
```

The deploy recipe reads the current run id from
`bench/transport/.run/current`, resolves public SSH targets from Terraform
outputs, and writes one log per target under
`bench/transport/results/<run_id>/`. Each role is a separate deploy unit; the
top-level deploy fails if either role fails.

For manual one-off targets, use the lower-level target recipe. The artifact
path is relative to `bench/transport/` unless absolute:

```bash
just bench-transport-deploy-target \
  root@203.0.113.10 \
  20260520T134420Z-smoke \
  build/artifacts/moqx-transport-bench-0.1.0-<git>-linux-arm64.tar.gz
```

Deployment copies the tarball, extracts it under
`/opt/moqx-bench/moqx-transport-bench/releases/<artifact-name>/`, updates the
`current` symlink, and runs:

```bash
/opt/moqx-bench/moqx-transport-bench/current/bin/moqx-transport-bench help
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
bench/transport/results/
bench/transport/results/<run_id>.json
bench/transport/results/<run_id>.jsonl
```

## Ephemeral Infrastructure

Controlled server-pair benchmarks may use repo-owned Terraform under
`bench/transport/infra/` when the infrastructure is short-lived, explicit, and
destroyed by the caller after the run. Provisioning is separate from benchmark
tools: benchmark tasks must accept endpoints and must not call Terraform
themselves.

The first supported target is Hetzner Cloud:

```text
bench/transport/infra/hetzner/
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
