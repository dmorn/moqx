# Add reference QUIC benchmark scripts

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add benchmark scripts that compare `MOQX.Transport` against the selected reference QUIC implementation in both directions across caller-provided real server paths: our client to a reference server, and a reference client to our listener.

This isolates client-side and listener-side behavior while measuring raw transport characteristics and MOQT-shaped pressure patterns rather than full MOQT session semantics.

## Acceptance criteria

- [ ] A script measures `MOQX.Transport` client behavior against the selected reference server.
- [ ] A script measures selected reference client behavior against a `MOQX.Transport` listener.
- [ ] Scripts accept caller-provided endpoints for same-region, cross-region, and edge-to-server paths.
- [ ] Measurements include handshake latency, first-byte latency, stream throughput, datagram behavior where available, latency percentiles, resource usage, and stall/backpressure indicators.
- [ ] Scripts can run stream pressure, datagram pressure, and mixed control-plus-object patterns defined by issue 08.
- [ ] Scripts document how to start any required external reference process.
- [ ] Output follows the shared benchmark metadata/result schema defined by issue 08 and is comparable with the MOQX self-pair calibration benchmark.
- [ ] Any protocol mismatch or unsupported feature in the selected reference implementation is documented.

## Blocked by

- `.scratch/transport-layer-foundation/issues/10-add-moqx-quicer-self-pair-benchmark.md`

## Design decisions

- Real server paths are the primary evidence for these scripts.
- Reference-to-reference runs should be supported where practical so MOQX behavior can be compared against the same path without the BEAM in the loop.
- Full MOQT session semantics remain out of scope; mixed load should be transport-level control trickle plus object-like stream/datagram pressure.
- Public relays may be used separately as interop probes, but their results should not be mixed with controlled benchmark baselines.

## Progress

Issue 08 and issue 11 are closed. This issue remains blocked by the self-pair calibration script in issue 10.

## Comments
