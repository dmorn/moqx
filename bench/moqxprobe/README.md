# MOQXProbe

Standalone Mix project for caller-side transport benchmarks. It depends on the
root `moqx` library by path and exercises public transport APIs. It is not part
of the root library test suite.

## Contract

`docs/adr/0009-layered-benchmark-evidence-contract.md` is the benchmark
contract:

- Benchee scripts are closed-loop. They rank invocation service time; they are
  not bandwidth or saturation claims.
- `bench/paced_stream.exs` is open-loop. It offers payloads on a fixed schedule
  and is the saturation path.
- Every reported metric needs source layer, window, and tier.
- Fake and loopback runs are calibration only.
- Delivery evidence is collected after timing by target adapters.

## Install

```bash
cd bench/moqxprobe
mix deps.get
```

## Targets

- `--target fake`: in-process support target for process-model calibration.
- `--target quicprobe`: local or remote `bench/quicprobe` server.

Common real-target flags:

```bash
--host <target-host-or-ip>
--quic-port <quic-port>
--ca <ca.pem>
--servername <cert-name>
--alpn moqx-test
```

Run an `iperf3` preflight before interpreting real QUIC numbers:

```bash
iperf3 --client <target-host-or-ip> --port <iperf-port> --time 5 --json
iperf3 --client <target-host-or-ip> --port <iperf-port> --udp --bitrate 100M --time 5 --json
```

Keep those JSON outputs as sidecars or metadata. They are path baselines, not
QUIC measurements.

## Reference peer

Generate a loopback cert once:

```bash
../../scripts/gen-loopback-certs.sh ../../.tmp/integration-certs
```

Run `quicprobe` locally:

```bash
go run ../quicprobe server \
  --addr :4433 \
  --cert ../../.tmp/integration-certs/server.pem \
  --key ../../.tmp/integration-certs/server-key.pem \
  --alpn moqx-test \
  --stats-output results/quicprobe-evidence.jsonl \
  --datagram-semantics drain \
  --evidence-http-addr :55434
```

Useful `quicprobe` server flags:

- `--datagram-semantics drain|echo`: drain for `moqxprobe`, echo for
  round-trip reference-client checks.
- `--stats-output PATH`: server run evidence JSONL.
- `--evidence-http-addr ADDR`: evidence and experiment lease API.
- `--initial-packet-size BYTES`: use `1200` on Tailscale/1280-MTU paths.
- `--evidence-bin-ms N`: receiver interval bin width.
- `--object-size BYTES`: object-delivery delay tracking for fixed-size
  unidirectional stream payloads with timestamp headers.

HTTP API:

```text
GET  /healthz
GET  /evidence/latest
GET  /evidence/runs?after_sequence=N
GET  /experiment/lease
POST /experiment/lease/acquire
POST /experiment/lease/release
```

Do not run parallel suites against one `quicprobe` target. `moqxprobe` leases
the target before real-target suites and matches receiver evidence by lease
token and target-local run sequence.

## Closed-loop streams

Fake target:

```bash
mix run bench/stream_clients.exs -- \
  --target fake \
  --implementation flow_partitions \
  --input flow-generated \
  --stream-count 32 \
  --payload-count 1000 \
  --payload-size 1180 \
  --stream-send-window 16 \
  --benchee-time 3
```

`quicprobe` target with delivery evidence:

```bash
mix run bench/stream_clients.exs -- \
  --target quicprobe \
  --host <target-host-or-ip> \
  --quic-port <quic-port> \
  --ca <ca.pem> \
  --servername <cert-name> \
  --stream-count 32 \
  --payload-count 1000 \
  --evidence-output results/quicprobe-stream-evidence.jsonl
```

Common stream flags:

- `--implementation NAME`: repeatable; current baseline is `flow_partitions`.
- `--input NAME`: repeatable input source.
- `--stream-count N`, `--payload-count N`, `--payload-size BYTES`.
- `--stream-send-window N`: per-stream send-completion credit.
- `--sender-shard-count N`: shard/partition count for sharded implementations.
- `--flow-stages N`: ordered stream workloads require `1`.
- `--min-demand N`, `--max-demand N`, `--max-queue-depth N`.
- `--benchee-warmup SEC`, `--benchee-time SEC`,
  `--benchee-parallel N`.
- `--save PATH`: saved Benchee suite.

Evidence and host sampling require `--benchee-parallel 1`.

## Closed-loop DATAGRAMs

Fake target:

```bash
mix run bench/datagram_clients.exs -- \
  --target fake \
  --datagram-count 10000 \
  --datagram-rate 30000 \
  --datagram-size 1180 \
  --benchee-time 3
```

`quicprobe` target:

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

Run the server with `--datagram-semantics drain`. Use `echo` only when a
reference client expects returned DATAGRAMs.

Common DATAGRAM flags:

- `--datagram-count N`, `--datagram-rate N`, `--datagram-size BYTES`.
- `--datagram-send-flag NAME`: repeatable quicer flag.
- `--max-burst N`, `--max-queue-depth N`, `--min-demand N`, `--max-demand N`.
- `--flow-stages N`, `--max-lag-ms N`, `--timeout-ms N`.

## Open-loop paced streams

Open-loop mode offers work on wall-clock ticks. Do not compare its numbers with
Benchee `ips`.

Fake target:

```bash
mix run bench/paced_stream.exs -- \
  --target fake \
  --offered-rate 50000 \
  --tick-ms 1 \
  --duration-ms 3000 \
  --stream-count 32 \
  --payload-size 1180 \
  --paced-output results/paced.jsonl
```

`quicprobe` target with evidence:

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

Core paced flags:

- `--offered-rate N`: payload events/sec, or bytes/sec with
  `--rate-mode bytes`.
- `--rate-mode payload-events|bytes`.
- `--tick-ms N`, `--duration-ms N`, `--stream-count N`,
  `--payload-size BYTES`, `--drain-ms N`.
- `--backlog-threshold N`, `--sustained-lag-ms N`,
  `--sustained-lag-ticks N`, `--warmup-ms N`,
  `--completion-deficit-threshold R`.
- `--paced-output PATH`, `--tier TIER`.

The `saturated` verdict comes from completion deficit or backlog. The
`coordinated_omission` flag is sender-scheduling evidence. Treat lag without
saturation as jitter, not a path claim.

For object-delivery delay, run `quicprobe server --object-size <payload-size>`.
The report derives delay above the run minimum; absolute one-way latency across
unsynced hosts is not recoverable.

## Evidence sidecars

Shared flags:

- `--evidence-output PATH`: post-run delivery evidence JSONL.
- `--evidence-timeout-ms N`, `--evidence-poll-ms N`,
  `--evidence-close-grace-ms N`.
- `--quicprobe-evidence-url URL`: default `http://<host>:55434`.
- `--quicprobe-evidence-port N`: default `55434`.
- `--quicprobe-evidence-path PATH`: local server JSONL fallback.
- `--host-sample-ms N` and `--host-samples-output PATH`: out-of-band BEAM/host
  sampler; both required together.
- `--manifest-output PATH`: `moqxprobe-run-manifest-v1`.
- `--git-sha SHA`, `--iperf-preflight-summary PATH`,
  `--tailscale-path-mode MODE`, `--server-stats-path PATH`.

Delivery evidence is adapter-owned and unmeasured. The timed function returns a
receipt; the hook closes/drains as needed and collects receiver evidence.

## Manifest and report

Write a run manifest:

```bash
mix run bench/stream_clients.exs -- \
  --target fake \
  --implementation flow_partitions \
  --evidence-output results/run/delivery-evidence.jsonl \
  --host-sample-ms 100 \
  --host-samples-output results/run/host-samples.jsonl \
  --manifest-output results/run/manifest.json
```

Generate `report.md`:

```bash
mix run bench/report.exs -- --run-dir results/run
# or
mix run bench/report.exs -- --manifest results/run/manifest.json --output results/run/report.md
```

The report derives named metrics, warns on ambiguous or cross-mode comparisons,
and records its path back into the manifest.

## Development gate

For code changes in this project:

```bash
cd bench/moqxprobe
mix format --check-formatted
mix test
mix credo --strict
```

Docs-only changes do not require the Elixir gate.
