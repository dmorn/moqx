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
  --stats-output <run-evidence.jsonl>
```

The server emits one compact `server_run_evidence` JSON record per completed
connection to stdout and to `--stats-output` when configured. The record is
receiver-side evidence, not a client benchmark result: bidirectional streams
are echoed, unidirectional streams are drained and counted, and DATAGRAMs are
handled according to `--datagram-semantics`.
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
