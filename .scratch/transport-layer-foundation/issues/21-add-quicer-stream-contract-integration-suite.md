# Add quicer stream contract integration suite

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Run the stream lifecycle contract against `MOQX.Transport.Quicer` using the real QUIC integration harness.

This moves the remaining real-backend criterion from the stream contract issue into an explicit integration-test slice, because it requires Docker/certificates/UDP/reference tooling and should not run in the default test suite.

## Acceptance criteria

- [x] The suite is tagged `:integration` and excluded by default.
- [x] The suite verifies bidirectional stream open/accept against the real quicer backend.
- [x] The suite verifies unidirectional stream open/accept against the real quicer backend.
- [x] The suite verifies stream direction and initiator metadata where `quicer` exposes enough information.
- [x] The suite verifies many concurrent bidirectional streams where backend stream limits permit it.
- [x] The suite verifies stream send and passive receive.
- [x] The suite verifies normalized active stream data delivery.
- [x] Any deviations between `quicer` event metadata and the support transport contract are documented and either normalized or split into follow-up issues.

## Blocked by

- `.scratch/transport-layer-foundation/issues/19-add-quicer-client-to-reference-server-integration.md`
- `.scratch/transport-layer-foundation/issues/20-add-reference-client-to-quicer-listener-integration.md`

## Comments

- 2026-05-07: Added `MOQX.Integration.QuicerSelfPairContractTest`, reusing centralized `:self_pair` contract against a real local `MOQX.Transport.Quicer` client/listener pair. Added `QuicerSelfPairFixture` glue that reads static listener cert/ALPN config and keeps cleanup in the owning test process. Normalized quicer stream metadata in the adapter: local `start_completed` direction comes from `stream_id`; peer `new_stream` direction comes from flags/stream id. Deviation: sync `quicer.accept_stream/3` returns an accepted stream without delivering a separate owner `new_stream` message, so the adapter emits the normalized transport event after accept.
