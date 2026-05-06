# Add stream lifecycle contract

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Establish shared stream lifecycle behavior across the support transport and `quicer` adapter: opening streams, accepting streams, sending stream data, receiving stream data, and observing stream events.

This gives future MOQT control-stream and data-stream code a tested foundation.

## Acceptance criteria

- [ ] Shared contract tests cover local stream open and remote stream accept.
- [ ] Shared contract tests cover stream send and passive receive.
- [ ] Shared contract tests cover normalized active stream data delivery.
- [ ] The support transport passes the stream contract tests.
- [ ] The `quicer` adapter passes the same stream contract tests where local environment support is available.
- [ ] Stream event metadata exposed through the transport contract is documented enough for protocol users.

## Blocked by

- `.scratch/transport-layer-foundation/issues/03-add-support-transport-connection-lifecycle.md`

## Comments
