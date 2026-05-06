# Add close and ownership contract

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Establish transport behavior for stream close, connection close, and process ownership handoff.

This slice makes process-boundary and shutdown behavior explicit before MOQT session and request lifecycle code depends on it.

## Acceptance criteria

- [ ] Shared contract tests cover stream close behavior and normalized stream close events.
- [ ] Shared contract tests cover connection close behavior and normalized connection close events.
- [ ] Shared contract tests cover `controlling_process/2` for connection and stream handles where supported.
- [ ] The support transport updates ownership and message delivery according to the contract.
- [ ] The `quicer` adapter passes the same close/ownership contract tests where local environment support is available.
- [ ] Any unsupported or backend-limited ownership behavior is explicitly documented.

## Blocked by

- `.scratch/transport-layer-foundation/issues/04-add-stream-lifecycle-contract.md`
- `.scratch/transport-layer-foundation/issues/05-add-datagram-contract.md`

## Comments
