# Add support transport connection lifecycle

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Introduce the deterministic in-memory support transport with the smallest complete client/server connection lifecycle: listen, connect, accept, and handshake.

This slice should make it possible for future protocol tests to establish a fake QUIC-like connection without opening real sockets. It must not assume only MOQT draft-14; it should support protocol-selected ALPN and capability profiles usable by both MOQT draft-14 and MOQ Lite tests.

## Acceptance criteria

- [ ] A support transport module implements the `MOQX.Transport` behaviour for listener and connection lifecycle callbacks.
- [ ] A test can start a listener, connect a client, accept a server-side connection, and complete handshake deterministically.
- [ ] Tests can configure negotiated ALPN/capability profiles for draft-14-like and MOQ Lite-like sessions.
- [ ] Connection handles are opaque to callers.
- [ ] The support transport emits normalized connection/listener events compatible with the transport event vocabulary.
- [ ] The implementation is isolated to test support and does not become a production dependency.

## Blocked by

- `.scratch/transport-layer-foundation/issues/01-establish-normalized-transport-event-helper.md`
- `.scratch/transport-layer-foundation/issues/13-add-configurable-alpn-and-capability-surface.md`

## Comments
