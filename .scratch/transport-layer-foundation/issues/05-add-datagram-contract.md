# Add datagram contract

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Establish shared datagram behavior across the support transport and `quicer` adapter, including send, receive, and normalized datagram events.

This gives future MOQT object-datagram work a tested foundation while preserving datagram unreliability semantics.

## Acceptance criteria

- [ ] Shared contract tests cover sending a binary datagram from one peer and receiving it at the other peer.
- [ ] Datagram payloads remain binaries.
- [ ] Normalized datagram events do not expose raw backend message shapes.
- [ ] The support transport can simulate successful datagram delivery deterministically.
- [ ] The `quicer` adapter passes the same datagram contract tests where local environment support is available.
- [ ] The contract documents that datagram delivery is unreliable even when the support transport can be configured deterministically.

## Blocked by

- `.scratch/transport-layer-foundation/issues/03-add-support-transport-connection-lifecycle.md`

## Comments
