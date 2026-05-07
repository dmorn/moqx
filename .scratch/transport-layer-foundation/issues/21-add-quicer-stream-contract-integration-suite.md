# Add quicer stream contract integration suite

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Run the stream lifecycle contract against `MOQX.Transport.Quicer` using the real QUIC integration harness.

This moves the remaining real-backend criterion from the stream contract issue into an explicit integration-test slice, because it requires Docker/certificates/UDP/reference tooling and should not run in the default test suite.

## Acceptance criteria

- [ ] The suite is tagged `:integration` and excluded by default.
- [ ] The suite verifies bidirectional stream open/accept against the real quicer backend.
- [ ] The suite verifies unidirectional stream open/accept against the real quicer backend.
- [ ] The suite verifies stream direction and initiator metadata where `quicer` exposes enough information.
- [ ] The suite verifies many concurrent bidirectional streams where backend stream limits permit it.
- [ ] The suite verifies stream send and passive receive.
- [ ] The suite verifies normalized active stream data delivery.
- [ ] Any deviations between `quicer` event metadata and the support transport contract are documented and either normalized or split into follow-up issues.

## Blocked by

- `.scratch/transport-layer-foundation/issues/19-add-quicer-client-to-reference-server-integration.md`
- `.scratch/transport-layer-foundation/issues/20-add-reference-client-to-quicer-listener-integration.md`

## Comments
