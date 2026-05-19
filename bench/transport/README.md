# Transport Benchmark Harness

This directory is for transport performance and limit research. It is not part
of normal tests, ExUnit integration tests, or the commit-time correctness
checklist.

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

The harness supports these benchmark families. Individual scripts may implement
them incrementally, but they must use the shared output schema.

### Path Baseline

Use `iperf3` to establish raw host/path capacity:

- TCP throughput baseline.
- UDP offered-rate sweep.
- UDP loss and jitter at each offered rate.

`iperf3` is not a QUIC or MOQT benchmark. It is the path ceiling used to
interpret QUIC results.

The repo-owned script is:

```bash
elixir bench/transport/scripts/iperf3_baseline.exs --server <host-or-ip>
```

It expects the caller to provide an `iperf3` server endpoint. For local smoke
validation only, it can start a temporary loopback server:

```bash
elixir bench/transport/scripts/iperf3_baseline.exs \
  --server 127.0.0.1 \
  --port 55201 \
  --local-server \
  --tcp-duration 1 \
  --udp-duration 1 \
  --udp-bitrates 1M
```

For remote controlled paths, start `iperf3 --server` on the server host
yourself and pass the public or private endpoint explicitly. The script does
not provision infrastructure, start Terraform, or assume loopback.

### Self-Pair Calibration

Run `MOQX.Transport.Quicer` client and listener on the same host or loopback.

This measures local overhead:

- BEAM scheduling and mailbox behavior.
- `quicer` adapter overhead.
- host CPU and memory behavior.
- harness measurement overhead.

Self-pair results must be labeled `loopback_calibration`.

### Reference Comparison

Run the selected reference QUIC implementation on controlled server paths:

- `moqx` client to reference server.
- reference client to `moqx` listener.
- reference client to reference server where practical.

Reference-to-reference results help separate path/tool limits from `moqx`
limits.

### Pressure Patterns

Scripts should model transport-level pressure patterns before full protocol
semantics exist:

- stream pressure: one stream, many streams, bidirectional streams,
  unidirectional streams;
- datagram pressure: fixed-size datagrams at stepped offered rates;
- mixed MOQT-shaped pressure: a low-rate control stream plus object-like
  unidirectional streams and/or datagrams.

Mixed pressure is not a full MOQT session. It is a transport pattern shaped
like MOQT data-plane pressure.

## Protocol Profiles

Benchmark scripts should accept a protocol-like profile argument.

Initial profiles:

- `draft14_like`
  - ALPN: `moq-00` unless overridden.
  - QUIC DATAGRAM: enabled.
  - Workloads may use one control-like bidirectional stream plus
    unidirectional object streams and/or datagrams.
- `moq_lite_like`
  - ALPN: `moq-lite-04` unless overridden.
  - QUIC DATAGRAM: disabled.
  - Workloads may use many bidirectional transaction-like streams and
    unidirectional group-like streams.

Profiles are transport fixtures. They do not implement full protocol rules.

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

Stop thresholds are script parameters. #08 defines the shape, not universal
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

Scripts should record the first observed symptom and any final close/error
reason.

## Output Format

Benchmark scripts must emit machine-readable JSON or JSONL. JSONL is preferred
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
    "script": "bench/transport/scripts/example.exs",
    "script_version": "v1",
    "command": "mix run bench/transport/scripts/example.exs -- ...",
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
    "name": "draft14_like",
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

## Script Conventions

Elixir benchmark scripts should be standalone `.exs` files. Use
`Mix.install/1` only when a script has explicit script-local dependencies; a
no-dependency script should stay a plain `.exs` file. Non-Elixir tools are
allowed when they are the benchmark subject or selected reference tool.

Scripts must:

- accept caller-provided endpoints;
- avoid mutating `Application` env as a test seam;
- avoid adding benchmark-only dependencies to `mix.exs`;
- print JSON or JSONL to stdout;
- write optional artifacts under `bench/transport/results/` or a caller-provided
  output directory;
- include enough command parameters in output to reproduce the run.

Scripts should not:

- start cloud/server infrastructure implicitly;
- start Docker implicitly unless the script is explicitly a local calibration
  helper;
- treat public relay results as controlled performance baselines;
- hide failed runs by omitting output.

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
scripts: scripts must accept endpoints and must not call Terraform themselves.

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
runs. Benchmark scripts should merge those outputs with live host inventory and
run-specific metrics.

## Implementation Order

The intended issue order is:

1. Define this contract (#08).
2. Add ephemeral controlled-server infrastructure (#22).
3. Add raw path baseline scripts (#09).
4. Add self-pair calibration scripts (#10).
5. Select the first reference QUIC implementation and topology (#11).
6. Add real-path reference benchmark scripts (#12).
