# Bench

Benchmark-related projects live under `bench/`.

Active layout:

- `moqxprobe/` is the Elixir benchmark project for caller-side transport
  clients, Benchee stream/DATAGRAM scripts, local telemetry summaries, and
  target adapters.
- `quicprobe/` is the repo-owned Go/quic-go reference QUIC peer used as a
  local or remote target.

Benchmark commands accept explicit target data such as host, QUIC port,
certificate path, and workload shape. They do not create cloud resources,
deploy artifacts, start Terraform, or infer state from a previous lab run.

The current performance loop is intentionally small:

1. Keep a target machine running `iperf3` and `quicprobe`, or run `quicprobe`
   locally.
2. Run `iperf3` manually as a preflight/path baseline for that target.
3. Run `bench/moqxprobe` Benchee scripts against either a fake transport target
   for process-model isolation or a real `quicprobe` target for QUIC behavior.
4. Save Benchee output plus optional sidecar notes for target metadata,
   `iperf3` baselines, `quicprobe` receiver evidence, telemetry summaries, and
   packet captures.

`quicprobe server` emits one `quicprobe-server-run-evidence-v1`
`server_run_evidence` JSON record for each completed connection. The record is
written to server stdout and, when configured, to `--stats-output` as JSONL.
Those records are the receiver-side truth for stream bytes, stream echo bytes,
DATAGRAM receive counts, optional DATAGRAM echo counts, and error counters.
Server DATAGRAM behavior is explicit: `--datagram-semantics drain` is the
publish-only receiver-evidence mode, while `--datagram-semantics echo` is for
round-trip/reference-client checks.
The same records are also available through the server's always-on evidence
HTTP API, defaulting to `:55434`, so local and remote `moqxprobe` runs can
scrape evidence through the same adapter.

Do not run parallel benchmark suites against the same `quicprobe` target.
Receiver evidence is connection-sequence based, and concurrent experiments
would contaminate both timing and evidence attribution. `moqxprobe` acquires an
exclusive experiment lease from the target HTTP API before each `quicprobe`
suite and releases it after the suite; a second suite receives a conflict
instead of running.

Historical Terraform, `probed`, release-deploy, ledger, and
`transport-bench-v1` JSONL tooling has been removed from the active benchmark
surface. Old issue comments and archived result directories may still mention
those names as historical evidence.
