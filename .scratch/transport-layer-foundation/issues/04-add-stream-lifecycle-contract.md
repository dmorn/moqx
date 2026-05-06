# Add stream lifecycle contract

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Establish shared stream lifecycle behavior across the support transport and `quicer` adapter: opening streams, accepting streams, sending stream data, receiving stream data, and observing stream events.

The contract must model generic QUIC streams rather than a draft-14-only single-control-stream assumption. Draft-specific rules such as “first stream is client-initiated bidirectional control stream” or “many bidirectional transaction streams are allowed” belong above transport.

## Acceptance criteria

- [ ] Shared contract tests cover local stream open and remote stream accept for bidirectional streams.
- [ ] Shared contract tests cover local stream open and remote stream accept for unidirectional streams.
- [ ] Stream events expose direction and initiator metadata sufficient for higher layers to enforce protocol-specific stream rules.
- [ ] Shared contract tests cover many concurrent bidirectional streams for MOQ Lite-style transaction use.
- [ ] Shared contract tests cover stream send and passive receive.
- [ ] Shared contract tests cover normalized active stream data delivery.
- [ ] The contract documents per-stream ordering and explicitly does not promise cross-stream ordering.
- [ ] The support transport passes the stream contract tests.
- [ ] The `quicer` adapter passes the same stream contract tests where local environment support is available.

## Blocked by

- `.scratch/transport-layer-foundation/issues/03-add-support-transport-connection-lifecycle.md`

## Comments
