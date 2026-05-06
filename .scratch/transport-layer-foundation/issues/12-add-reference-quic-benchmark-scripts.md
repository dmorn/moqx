# Add reference QUIC benchmark scripts

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add benchmark scripts that compare `MOQX.Transport` against the selected reference QUIC implementation in both directions: our client to a reference server, and a reference client to our listener.

This isolates client-side and listener-side behavior while continuing to measure raw transport characteristics rather than MOQT semantics.

## Acceptance criteria

- [ ] A script measures `MOQX.Transport` client behavior against the selected reference server.
- [ ] A script measures selected reference client behavior against a `MOQX.Transport` listener.
- [ ] Measurements include handshake latency, first-byte latency, stream throughput, and datagram behavior where available.
- [ ] Scripts document how to start any required external reference process.
- [ ] Output format is comparable with the MOQX self-pair benchmark.
- [ ] Any protocol mismatch or unsupported feature in the selected reference implementation is documented.

## Blocked by

- `.scratch/transport-layer-foundation/issues/10-add-moqx-quicer-self-pair-benchmark.md`
- `.scratch/transport-layer-foundation/issues/11-select-reference-quic-implementation.md`

## Comments
