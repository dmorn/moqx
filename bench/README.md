# Bench

Benchmark-related projects live under `bench/`.

## Layout

- `moqxprobe/`: Elixir benchmark project for caller-side transport clients,
  Benchee stream/DATAGRAM scripts, open-loop paced streams, local telemetry
  summaries, manifests, reports, and target adapters.
- `quicprobe/`: repo-owned Go/quic-go reference peer used locally or remotely.

Benchmark commands accept explicit target data: host, QUIC port, certificate,
server name, evidence URL/path, workload shape, and output paths. They do not
create cloud resources, deploy artifacts, start Terraform, or infer state from
old lab runs.

## Active loop

1. Keep a target machine running `iperf3` and `quicprobe`, or run `quicprobe`
   locally.
2. Run `iperf3` manually as a same-path preflight.
3. Run `bench/moqxprobe` against `--target fake` for process-model calibration
   or `--target quicprobe` for QUIC behavior.
4. Save Benchee/open-loop output plus optional sidecars: manifest,
   delivery evidence, host samples, paced stream rows, iperf3 baselines,
   target metadata, captures, and flamegraphs.
5. Generate `report.md` from the run manifest when a derived summary is needed.

See `bench/moqxprobe/README.md` for commands and `docs/adr/0009-*` for the
evidence contract.

## quicprobe evidence

`quicprobe server` emits one `quicprobe-server-run-evidence-v1`
`server_run_evidence` JSON record per completed connection. It writes to stdout
and, when configured, `--stats-output` as JSONL.

The record is receiver-side truth for stream bytes, stream echo bytes, DATAGRAM
receive counts, optional DATAGRAM echo counts, interval bins, lifecycle
timestamps, lease owner/token, and error counters.

Server DATAGRAM behavior is explicit:

- `--datagram-semantics drain`: publish-only receiver-evidence mode for
  `moqxprobe`.
- `--datagram-semantics echo`: round-trip/reference-client checks.

The server exposes the evidence and experiment lease HTTP API on
`--evidence-http-addr` (default `:55434`). Do not run parallel benchmark suites
against one `quicprobe` target; `moqxprobe` acquires an exclusive lease before
real-target suites and fails fast when the target is busy.

## Transport status

Transport benchmarking is parked. The evidence loop lives in `bench/` and is
ready to support MOQ protocol work.

Parked follow-ups:

- deterministic transport failure injection;
- QUIC priority, flow-control, and stats surfaces;
- deeper client pressure work only if protocol runs expose a real bottleneck;
- shared bench-script helper extraction for lease/evidence/sidecar plumbing;
- multi-Gbps/path or parallel-receiver studies only for a concrete need.

Historical Terraform, `probed`, release-deploy, ledger, and
`transport-bench-v1` tooling are retired. Preserve old result artifacts as
history; do not add new work to those paths.
