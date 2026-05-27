# Decide MOQX listener performance peer model

Status: ready-for-human
Type: HITL

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Decide whether `moqx-transport-bench moqx-listener` should remain a correctness
peer or become a serious performance peer.

The current listener is valuable because it exercises the real
`MOQX.Transport.Quicer` listener path, but it was not designed as an optimized
server. Stream evidence shows listener-side goodput plateauing well below the
reference peer, while DATAGRAM evidence is clean through the currently valid
offered-rate range. Before optimizing it, we need a deliberate decision about
what the listener is supposed to prove.

## Acceptance criteria

- [ ] The decision records whether `moqx-listener` remains a correctness peer,
      becomes a performance peer, or is split into separate correctness and
      performance commands.
- [ ] The decision records the expected serving model if performance mode is
      pursued: per-stream workers, bounded event pump, connection-level router,
      or another explicit model.
- [ ] The benchmark README and #26 are updated with the listener role and the
      limits of listener-side capacity claims.
- [ ] If performance mode is chosen, a focused AFK implementation issue is
      opened with concrete acceptance criteria.

## Blocked by

#33 - stream-pressure diagnostics should inform this decision.

## Notes

This is intentionally HITL. The wrong choice here can turn a simple correctness
peer into a second benchmark server implementation with unclear ownership.
