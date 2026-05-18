# Select reference QUIC implementation

Status: ready-for-human
Type: HITL

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Choose the first reference QUIC implementation and remote benchmark topology to use in transport benchmark comparisons.

The decision should optimize for useful real-path performance signal, local developer ergonomics, deployability on remote servers, and scriptability. Candidates discussed include `quic-go`, `ngtcp2`, `picoquic`, and `quiche`.

## Acceptance criteria

- [ ] A reference QUIC implementation is selected for the first benchmark iteration.
- [ ] The decision records why this implementation was selected over the other candidates.
- [ ] Installation/setup requirements are documented.
- [ ] Remote server topology requirements are documented, including same-region and cross-region server pairs.
- [ ] The selected implementation can support configurable ALPN for protocol-like benchmark profiles.
- [ ] The selected implementation can support a simple stream/datagram measurement protocol or a practical equivalent.
- [ ] The selected implementation can run as both a remote server and remote client where needed for bidirectional path comparisons.
- [ ] Any missing datagram, priority, or stats capability is documented.
- [ ] Follow-up benchmark issues can assume this choice without reopening the decision.

## Blocked by

None - issue 08 is closed.

## Design decisions

- This is a human-in-the-loop decision because remote server availability, deployability, and operational ergonomics matter as much as library capability.
- The repo-owned `tools/quicprobe` path remains a strong candidate for the first reference implementation because it already uses quic-go and is scriptable, but #11 should still record the tradeoff explicitly.
- The benchmark topology should favor caller-provided servers over public relays. Public relays are interop probes, not controlled baselines.
- The first decision does not need to select a permanent reference implementation forever.

## Progress

Issue 08 is closed. This issue is now ready for the human-in-the-loop decision on the first reference implementation and remote benchmark topology.

## Comments
