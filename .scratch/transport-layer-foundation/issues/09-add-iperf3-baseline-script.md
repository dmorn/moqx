# Add iperf3 baseline script

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a raw host/network baseline script around `iperf3` so QUIC transport measurements can be interpreted relative to TCP/UDP capacity on the exact server path under test.

This script is a research aid, not a QUIC benchmark.

## Acceptance criteria

- [ ] A standalone benchmark script runs an `iperf3` TCP baseline.
- [ ] A standalone benchmark script runs an `iperf3` UDP baseline with configurable bitrate/duration.
- [ ] The script accepts caller-provided client/server endpoints rather than assuming loopback.
- [ ] The script records the shared benchmark metadata defined by issue 08.
- [ ] Output includes throughput and, for UDP, loss/jitter where available.
- [ ] Output uses the shared machine-readable result shape defined by issue 08.
- [ ] Documentation explains that `iperf3` establishes a network/host ceiling for the tested path, not expected QUIC or MOQT performance.

## Blocked by

None - issue 08 is closed.

## Design decisions

- Run `iperf3` against the same server pair/path used by QUIC benchmarks.
- Treat loopback `iperf3` only as calibration for local host limits.
- Capture TCP and UDP results separately because UDP loss/jitter is part of the path context for QUIC DATAGRAM pressure tests.
- Do not compare QUIC goodput without the corresponding raw path baseline.

## Progress

Issue 08 is closed, so this issue is ready for an agent to implement against the benchmark contract in `bench/transport/README.md`.

## Comments
