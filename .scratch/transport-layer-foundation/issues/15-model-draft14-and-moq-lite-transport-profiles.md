# Model draft-14 and MOQ Lite transport profiles

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add lightweight transport-profile fixtures or helpers that express what MOQT draft-14 and MOQ Lite need from the generic transport layer, without implementing either full protocol.

These profiles should be used to prove the support transport and contract tests do not accidentally bake in a single protocol's assumptions.

## Acceptance criteria

- [ ] A draft-14-like profile configures native QUIC ALPN `moq-00`, datagram availability, one client-initiated bidirectional control stream expectation at the protocol-test level, and unidirectional data stream support.
- [ ] A MOQ Lite-like profile configures a `moq-lite-xx`-style ALPN, no datagrams, many bidirectional transaction streams, and unidirectional group stream support.
- [ ] Tests demonstrate the transport layer supports both profiles without changing transport implementation code.
- [x] Tests cover at least draft-14-like and MOQ Lite-like capability profiles in the support transport.
- [ ] Draft-specific stream validation is kept outside the transport implementation.
- [ ] Profile documentation clarifies that these are contract fixtures, not full protocol implementations.

## Blocked by

None - issues 13, 04, and 05 are closed.

## Progress

The support-transport-specific capability-profile criterion was moved here from issue 13 after issue 13 delivered the production capability surface in commit `746257a`.

Issue 03 added support transport profile coverage for draft-14-like and MOQ
Lite-like capabilities. Issues 04, 05, and 13 are now closed, so the remaining
profile fixture/documentation work is structurally unblocked.

## Comments

- 2026-05-19: Marked ready after stale blockers were cleared. This can be
  implemented before or alongside issue 10 because the self-pair calibration
  benchmark needs the same draft-14-like and MOQ Lite-like profile vocabulary.
