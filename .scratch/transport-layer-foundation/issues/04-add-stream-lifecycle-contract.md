# Add stream lifecycle contract

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Establish shared stream lifecycle behavior across the support transport and `quicer` adapter: opening streams, accepting streams, sending stream data, receiving stream data, and observing stream events.

The contract must model generic QUIC streams rather than a draft-14-only single-control-stream assumption. Draft-specific rules such as “first stream is client-initiated bidirectional control stream” or “many bidirectional transaction streams are allowed” belong above transport.

## Acceptance criteria

- [x] Shared contract tests cover local stream open and remote stream accept for bidirectional streams.
- [x] Shared contract tests cover local stream open and remote stream accept for unidirectional streams.
- [x] Stream events expose direction and initiator metadata sufficient for higher layers to enforce protocol-specific stream rules.
- [x] Shared contract tests cover many concurrent bidirectional streams for MOQ Lite-style transaction use.
- [x] Shared contract tests cover stream send and passive receive.
- [x] Shared contract tests cover normalized active stream data delivery.
- [x] The contract documents per-stream ordering and explicitly does not promise cross-stream ordering.
- [x] The support transport passes the stream contract tests.

## Blocked by

- `.scratch/transport-layer-foundation/issues/03-add-support-transport-connection-lifecycle.md`

## Resolution

Implemented shared stream contract tests and support transport stream lifecycle behavior:

- bidirectional stream open/accept;
- unidirectional stream open/accept;
- stream direction and initiator metadata in normalized events;
- many concurrent bidirectional streams;
- passive stream send/receive with per-stream ordering;
- active stream data delivery through normalized `MOQX.Transport.event()` values.

The real `MOQX.Transport.Quicer` backend contract was moved to explicit integration-test issues because it requires Docker/certificates/UDP/reference tooling and should be tagged `:integration`, not run in the default suite. See `.scratch/transport-layer-foundation/issues/21-add-quicer-stream-contract-integration-suite.md`.

## Comments
