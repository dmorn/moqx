# MOQXProbe

`bench/moqxprobe` is a standalone Mix project for transport benchmark clients.
It depends on the root `moqx` library by path and exercises public transport
APIs. It is not part of the root library test suite.

The active goal is caller-side performance work: compare process architectures
that publish over QUIC streams or DATAGRAMs, first in isolation and then
against a simple `quicprobe` target.

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
  --implementation stream_owner \
  --input flow-generated \
  --save results/stream-owner.benchee
```

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

The script exposes setup through flags, not environment variables or
`Application` configuration. Use `--help` for the full option list.

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
  --stats-output <run-evidence.jsonl>
```

The server emits one compact `server_run_evidence` JSON record per completed
connection to stdout and to `--stats-output` when configured. The record is
receiver-side evidence, not a client benchmark result: bidirectional streams
are echoed, unidirectional streams are drained and counted, and DATAGRAMs are
echoed and counted.

For remote VMs, keep `iperf3` and `quicprobe` running under systemd and deploy
new `quicprobe` artifacts with the root `just` recipes. VM setup and service
operation details live in the `exe-dev-vm-ops` skill.

## Artifact Policy

The active artifact story is intentionally small:

- Benchee saved suites or console output.
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
