# Add iperf3 baseline script

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a raw host/network baseline script around `iperf3` so QUIC transport measurements can be interpreted relative to TCP/UDP capacity on the same machine or path.

This script is a research aid, not a QUIC benchmark.

## Acceptance criteria

- [ ] A standalone benchmark script runs an `iperf3` TCP baseline.
- [ ] A standalone benchmark script runs an `iperf3` UDP baseline with configurable bitrate/duration.
- [ ] The script records enough metadata to understand the run environment and command parameters.
- [ ] Output includes throughput and, for UDP, loss/jitter where available.
- [ ] Documentation explains that `iperf3` establishes a network/host ceiling, not expected MOQT performance.

## Blocked by

- `.scratch/transport-layer-foundation/issues/08-create-transport-benchmark-harness-skeleton.md`

## Comments
