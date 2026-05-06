# Select reference QUIC implementation

Status: needs-triage
Type: HITL

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Choose the first reference QUIC implementation to use in transport benchmark comparisons.

The decision should optimize for useful interop/performance signal, local developer ergonomics, and scriptability. Candidates discussed include `quic-go`, `ngtcp2`, `picoquic`, and `quiche`.

## Acceptance criteria

- [ ] A reference QUIC implementation is selected for the first benchmark iteration.
- [ ] The decision records why this implementation was selected over the other candidates.
- [ ] Installation/setup requirements are documented.
- [ ] The selected implementation can support configurable ALPN for protocol-like benchmark profiles.
- [ ] The selected implementation can support a simple stream/datagram measurement protocol or a practical equivalent.
- [ ] Any missing datagram, priority, or stats capability is documented.
- [ ] Follow-up benchmark issues can assume this choice without reopening the decision.

## Blocked by

- `.scratch/transport-layer-foundation/issues/08-create-transport-benchmark-harness-skeleton.md`

## Comments
