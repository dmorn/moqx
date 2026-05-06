# Add datagram contract

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Establish shared datagram behavior across the support transport and `quicer` adapter, including capability discovery, send, receive, and normalized datagram events.

MOQT draft-14 requires QUIC DATAGRAM support and uses object datagrams. MOQ Lite does not use datagrams. The transport contract must therefore expose datagrams as a capability rather than as an unconditional assumption.

## Acceptance criteria

- [ ] A caller can discover whether datagrams are available for a connection/profile.
- [ ] A caller can discover max datagram payload size when the backend can provide it, or receive a documented `:unknown`/`:unsupported` result.
- [ ] Shared contract tests cover sending a binary datagram from one peer and receiving it at the other peer when datagrams are enabled.
- [ ] Shared contract tests cover datagram-unavailable behavior when datagrams are disabled or unsupported.
- [ ] Datagram payloads remain binaries.
- [ ] Normalized datagram events do not expose raw backend message shapes.
- [ ] The contract documents that datagram delivery is unreliable and must not be fragmented by the transport layer for MOQT object delivery.
- [ ] The support transport and `quicer` adapter pass the same datagram contract where applicable.

## Blocked by

- `.scratch/transport-layer-foundation/issues/03-add-support-transport-connection-lifecycle.md`
- `.scratch/transport-layer-foundation/issues/13-add-configurable-alpn-and-capability-surface.md`

## Comments
