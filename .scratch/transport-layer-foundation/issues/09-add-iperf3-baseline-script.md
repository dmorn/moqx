# Add iperf3 baseline script

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a raw host/network baseline tool around `iperf3` so QUIC transport measurements can be interpreted relative to TCP/UDP capacity on the exact server path under test.

This tool is a research aid, not a QUIC benchmark.

## Acceptance criteria

- [x] A standalone benchmark tool runs an `iperf3` TCP baseline.
- [x] A standalone benchmark tool runs an `iperf3` UDP baseline with configurable bitrate/duration.
- [x] The tool accepts caller-provided client/server endpoints rather than assuming loopback.
- [x] The tool records the shared benchmark metadata defined by issue 08.
- [x] Output includes throughput and, for UDP, loss/jitter where available.
- [x] Output uses the shared machine-readable result shape defined by issue 08.
- [x] Documentation explains that `iperf3` establishes a network/host ceiling for the tested path, not expected QUIC or MOQT performance.

## Blocked by

None.

## Design decisions

- Run `iperf3` against the same server pair/path used by QUIC benchmarks.
- Treat loopback `iperf3` only as calibration for local host limits.
- Capture TCP and UDP results separately because UDP loss/jitter is part of the path context for QUIC DATAGRAM pressure tests.
- Do not compare QUIC goodput without the corresponding raw path baseline.
- The first controlled non-production server topology is the Hetzner Terraform setup in `bench/transport/infra/hetzner/`. The task should still accept endpoints rather than invoking Terraform.

## Progress

Implemented by the nested benchmark Mix task
`bench/transport/lib/mix/tasks/moqx/transport/iperf3_baseline.ex`.

The task emits JSONL `step_summary` records using the shared benchmark schema.
It supports TCP, UDP offered-rate steps, caller-provided server endpoints,
optional path metadata JSON, and a local-only `--local-server` smoke helper.

Documentation was added to `bench/transport/README.md`.

Local validation:

- `cd bench/transport`
- `mix moqx.transport.iperf3_baseline --server 127.0.0.1 --port 55204 --local-server --tcp-duration 1 --udp-duration 1 --udp-bitrates 1M --output /private/tmp/moqx-iperf3-smoke.jsonl`
- Result: 2 JSONL records, TCP and UDP, both `iperf3_exit_status = 0`; UDP parsed goodput, delivery ratio, and jitter.

## Comments

- 2026-05-19: First controlled Hetzner smoke used `profiles/arm-smoke.tfvars`
  on the private `fsn1` to `nbg1` path. Result artifacts are local and ignored
  under `bench/transport/results/20260519-smoke/`: `path-metadata-private.json`,
  `terraform-output.json`, and `iperf3-private.jsonl`. The run produced three
  JSONL `step_summary` records: TCP, UDP at 10M, and UDP at 50M. All iperf3
  steps exited 0; TCP goodput was about 5.37 Gbps, and the 10M/50M UDP smoke
  steps reported full delivery for the short smoke window.
- 2026-05-20: Moved the iperf3 baseline into the standalone
  `bench/transport` Mix project. The task entrypoint is now
  `mix moqx.transport.iperf3_baseline` from `bench/transport/`; JSONL output
  remains `transport-bench-v1`.
- 2026-05-20: Added the runtime CLI entrypoint
  `moqx-transport-bench iperf3-baseline`. The Mix task remains as a local
  development wrapper over the same command path.
