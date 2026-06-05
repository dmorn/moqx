# Decide MOQX listener performance peer model

Status: closed
Type: HITL

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Decide whether the benchmark harness should keep a MOQX listener peer, split it
into correctness and performance modes, or drop it from the current caller-side
benchmark scope.

The old benchmark listener exercised the real `MOQX.Transport.Quicer` listener
path, but it was relay-side work. The current v1 target is caller-side: a
process that connects out to a relay, publishes streams/DATAGRAMs, or
subscribes and receives streams over an outbound QUIC connection.

## Acceptance criteria

- [x] The decision records whether the benchmark listener remains, becomes a
      performance peer, is split, or is dropped from v1.
- [x] The decision records that no serving model is pursued for v1.
- [x] The benchmark README and #26 are updated with listener/relay benchmarking
      as future scope.
- [x] If performance mode is chosen, a focused AFK implementation issue is
      opened with concrete acceptance criteria.

## Blocked by

None.

## Notes

This is intentionally HITL. The wrong choice here can turn a caller-side
benchmark harness into a second benchmark server implementation with unclear
ownership.

## Decision

- 2026-06-05: Drop the benchmark listener branch from the current v1 harness.
  Do not keep `moqxprobe moqx-listener` as a correctness peer, do not split it
  into correctness/performance modes, and do not optimize listener-side serving
  now. Listener/relay benchmarking is future relay work and should come back as
  a new issue with an explicit serving model when relays become a product
  target. The current benchmark surface stays caller-side: `measure` against
  `bench/quicprobe` reference peers plus local calibration tools.
