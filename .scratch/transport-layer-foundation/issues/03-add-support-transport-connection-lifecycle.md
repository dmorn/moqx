# Add support transport connection lifecycle

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Introduce the deterministic in-memory support transport with the smallest complete client/server connection lifecycle: listen, connect, accept, and handshake.

This slice should make it possible for future protocol tests to establish a fake QUIC-like connection without opening real sockets.

## Acceptance criteria

- [ ] A support transport module implements the `MOQX.Transport` behaviour for listener and connection lifecycle callbacks.
- [ ] A test can start a listener, connect a client, accept a server-side connection, and complete handshake deterministically.
- [ ] Connection handles are opaque to callers.
- [ ] The support transport emits normalized connection/listener events compatible with the transport event vocabulary.
- [ ] The implementation is isolated to test support and does not become a production dependency.

## Blocked by

- `.scratch/transport-layer-foundation/issues/01-establish-normalized-transport-event-helper.md`

## Comments
