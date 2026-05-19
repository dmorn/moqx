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

None - issue 06 is closed.

## Progress

Issue 06 is closed, so this issue is no longer structurally blocked.

Design direction:

- Configure support-transport impairments through backend-specific options on `MOQX.Transport.new(MOQX.Transport.Support, opts)`.
- Keep protocol/session choices such as `profile: :draft14` and `profile: :moq_lite` on `listen/connect`, not in the impairment config.
- Treat impairments as support-backend test machinery, not production transport semantics.
- Keep the default support transport reliable and deterministic when no impairment options are provided.
- Use explicit deterministic plans, counters, or fixed delays; do not add random loss unless a future design adds an explicit seeded mode.
- Do not use `Application` env or mutable global configuration as the test seam.

Implementation is intentionally deferred until a higher-level MOQT or MOQ Lite protocol test needs a concrete failure path. That should keep the first impairment API narrow and grounded in real caller needs instead of introducing a broad DSL prematurely.

## Comments
