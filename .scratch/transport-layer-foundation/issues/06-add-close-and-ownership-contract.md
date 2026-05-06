# Add close, reset, stop-sending, and ownership contract

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Establish transport behavior for graceful stream finish, stream reset, receive-side abort/STOP_SENDING, connection close, and process ownership handoff.

Both MOQT draft-14 and MOQ Lite distinguish successful stream completion from cancellation/expiry/error. The current shape where `close_stream/2` ignores the reason is insufficient for protocol layers that need to map application error codes to QUIC stream or connection shutdown behavior.

## Acceptance criteria

- [ ] The transport API distinguishes graceful stream FIN/send-side finish from RESET_STREAM.
- [ ] The transport API exposes STOP_SENDING or receive-side abort semantics where supported by the backend.
- [ ] Stream reset accepts an application error code/reason and preserves it in normalized peer events where available.
- [ ] Connection close accepts an application error code/reason and preserves it in normalized peer events where available.
- [ ] Shared contract tests cover graceful stream finish and normalized peer FIN/completion events.
- [ ] Shared contract tests cover stream reset and normalized peer reset events.
- [ ] Shared contract tests cover STOP_SENDING/receive-side abort behavior where supported.
- [ ] Shared contract tests cover connection close behavior and normalized connection close events.
- [ ] Shared contract tests cover `controlling_process/2` for connection and stream handles where supported.
- [ ] The support transport updates ownership and message delivery according to the contract.
- [ ] The `quicer` adapter passes the same close/reset/ownership contract tests where local environment support is available.
- [ ] Any unsupported or backend-limited ownership or stop-sending behavior is explicitly documented.

## Blocked by

- `.scratch/transport-layer-foundation/issues/04-add-stream-lifecycle-contract.md`
- `.scratch/transport-layer-foundation/issues/05-add-datagram-contract.md`

## Comments
