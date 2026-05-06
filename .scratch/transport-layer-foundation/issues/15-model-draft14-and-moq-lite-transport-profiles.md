# Model draft-14 and MOQ Lite transport profiles

Status: needs-triage
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
- [ ] Draft-specific stream validation is kept outside the transport implementation.
- [ ] Profile documentation clarifies that these are contract fixtures, not full protocol implementations.

## Blocked by

- `.scratch/transport-layer-foundation/issues/13-add-configurable-alpn-and-capability-surface.md`
- `.scratch/transport-layer-foundation/issues/04-add-stream-lifecycle-contract.md`
- `.scratch/transport-layer-foundation/issues/05-add-datagram-contract.md`

## Comments
