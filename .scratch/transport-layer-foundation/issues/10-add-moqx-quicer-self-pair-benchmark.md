# Add MOQX quicer self-pair benchmark

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a benchmark script that runs a `MOQX.Transport.Quicer` client against a `MOQX.Transport.Quicer` listener using a tiny measurement protocol over QUIC streams and datagrams.

This establishes baseline overhead for the Elixir transport wrapper, `quicer`, and the BEAM without introducing MOQT protocol semantics.

## Acceptance criteria

- [ ] A standalone Elixir script can start a local listener and client using `MOQX.Transport.Quicer`.
- [ ] The script measures handshake latency and first-byte latency.
- [ ] The script measures stream throughput for configurable payload size and duration/count.
- [ ] The script measures datagram send/receive rate where datagrams are available.
- [ ] Output is machine-readable enough to compare multiple runs.
- [ ] The script does not require adding benchmark dependencies to the library dependency graph.

## Blocked by

- `.scratch/transport-layer-foundation/issues/08-create-transport-benchmark-harness-skeleton.md`
- `.scratch/transport-layer-foundation/issues/04-add-stream-lifecycle-contract.md`
- `.scratch/transport-layer-foundation/issues/05-add-datagram-contract.md`

## Comments
