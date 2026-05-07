# Add datagram contract

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Establish shared datagram behavior across the support transport and `quicer` adapter, including capability discovery, send, receive, and normalized datagram events.

MOQT draft-14 requires QUIC DATAGRAM support and uses object datagrams. MOQ Lite does not use datagrams. The transport contract must therefore expose datagrams as a capability rather than as an unconditional assumption.

## Acceptance criteria

- [x] A caller can discover whether datagrams are available for a connection/profile.
- [x] A caller can discover max datagram payload size when the backend can provide it, or receive a documented `:unknown`/`:unsupported` result.
- [x] Shared contract tests cover sending a binary datagram from one peer and receiving it at the other peer when datagrams are enabled.
- [x] Shared contract tests cover datagram-unavailable behavior when datagrams are disabled or unsupported.
- [x] Datagram payloads remain binaries.
- [x] Normalized datagram events do not expose raw backend message shapes.
- [x] The contract documents that datagram delivery is unreliable and must not be fragmented by the transport layer for MOQT object delivery.
- [x] The support transport and `quicer` adapter pass the same datagram contract where applicable.

## Blocked by

- `.scratch/transport-layer-foundation/issues/03-add-support-transport-connection-lifecycle.md`
- `.scratch/transport-layer-foundation/issues/13-add-configurable-alpn-and-capability-surface.md`

## Comments

- 2026-05-07: Added centralized `:datagram` transport contract. Support transport now delivers binary datagrams as normalized `{:datagram, connection, payload, metadata}` events when the profile enables datagrams, and returns `{:error, :datagrams_unavailable}` when disabled. Quicer self-pair integration runs the same contract with draft14-style datagrams enabled via connection/listener opts. Quicer datagram flags are normalized into metadata maps; max datagram size remains `:unknown` where quicer does not expose it through the current capability query.
