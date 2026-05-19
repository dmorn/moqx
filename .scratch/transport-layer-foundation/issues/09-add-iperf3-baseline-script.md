# Add iperf3 baseline script

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a raw host/network baseline script around `iperf3` so QUIC transport measurements can be interpreted relative to TCP/UDP capacity on the exact server path under test.

This script is a research aid, not a QUIC benchmark.

## Acceptance criteria

- [x] A standalone benchmark script runs an `iperf3` TCP baseline.
- [x] A standalone benchmark script runs an `iperf3` UDP baseline with configurable bitrate/duration.
- [x] The script accepts caller-provided client/server endpoints rather than assuming loopback.
- [x] The script records the shared benchmark metadata defined by issue 08.
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
- The first controlled non-production server topology is the Hetzner Terraform setup in `bench/transport/infra/hetzner/`. The script should still accept endpoints rather than invoking Terraform.

## Progress

Implemented by `bench/transport/scripts/iperf3_baseline.exs`.

The script emits JSONL `step_summary` records using the shared benchmark schema.
It supports TCP, UDP offered-rate steps, caller-provided server endpoints,
optional path metadata JSON, and a local-only `--local-server` smoke helper.

Documentation was added to `bench/transport/README.md`.

Local validation:

- `elixir bench/transport/scripts/iperf3_baseline.exs --server 127.0.0.1 --port 55204 --local-server --tcp-duration 1 --udp-duration 1 --udp-bitrates 1M --output /private/tmp/moqx-iperf3-smoke.jsonl`
- Result: 2 JSONL records, TCP and UDP, both `iperf3_exit_status = 0`; UDP parsed goodput, delivery ratio, and jitter.

## Comments
