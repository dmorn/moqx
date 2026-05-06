# Add deterministic failure injection

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add controlled failure and impairment knobs to the support transport so protocol tests can exercise timeout, close, datagram loss, latency, and jitter paths without relying on real network flakiness.

This should remain deterministic by default and configurable per test.

## Acceptance criteria

- [ ] Tests can configure handshake failure deterministically.
- [ ] Tests can configure datagram loss deterministically.
- [ ] Tests can configure latency or delayed delivery deterministically.
- [ ] Tests can configure stream or connection close during an operation.
- [ ] Failure injection is opt-in; default support transport behavior remains reliable and deterministic.
- [ ] Documentation distinguishes support-transport impairment simulation from real QUIC performance behavior.

## Blocked by

- `.scratch/transport-layer-foundation/issues/06-add-close-and-ownership-contract.md`

## Comments
