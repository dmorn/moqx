# Redesign transport context, shutdown, and ownership contract

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Replace the current stateless `MOQX.Transport` behaviour shape with an explicit caller-owned transport context and use that redesign to establish unambiguous stream shutdown, connection close, stream-info, and ownership handoff semantics.

Both MOQT draft-14 and MOQ Lite need protocol code to distinguish successful completion from cancellation, expiry, peer abort, and session close. The current `close_stream/2` callback is ambiguous and currently discards the reason in the `quicer` adapter. The support transport also still returns `{:error, :not_implemented}` for close and ownership callbacks.

This issue should get the transport boundary right before higher-level protocol implementation starts, even though it is a breaking internal API redesign.

## Resolved design

### Public API goes through `MOQX.Transport`

Protocol-facing code should use the `MOQX.Transport` façade, not direct backend calls such as `MOQX.Transport.Quicer.open_stream/2`, except in backend-specific adapter tests.

The façade owns context threading, backend matching, wrapper construction, event normalization, and common validation.

### Caller-owned immutable context

Introduce an explicit single-owner transport context:

```elixir
{:ok, ctx} = MOQX.Transport.new(MOQX.Transport.Quicer, opts \\ [])
```

The context is immutable and caller-owned. Every operation that changes backend lookup state returns the updated context using context-last tuples:

```elixir
{:ok, value, ctx}
{:error, reason, ctx}
```

`receive_event/2` returns:

```elixir
{:ok, event, ctx}
{:timeout, ctx}
{:unknown, message, ctx}
{:error, reason, ctx}
```

Context usage invariant:

- A context has one logical owner process.
- Callers must thread the newest context value and must not use stale copies concurrently.
- Stale-context protection is by documentation plus loud normalization errors, not hidden mutable state.
- No `Application` env or mutable global test seam is introduced.

`Transport.new/2` options are backend machinery options only. Protocol/session choices such as ALPN, datagram enablement, and profile selection remain explicit on `listen/connect` calls.

### Backend references and wrapper handles

All public transport resources are stable MOQX wrapper structs with backend-private opaque data:

```elixir
%MOQX.Transport.Context{
  backend: %MOQX.Transport.BackendRef{module: module(), data: term()}
}

%MOQX.Transport.Listener{
  backend: %MOQX.Transport.BackendRef{module: module(), data: term()},
  local_role: :server
}

%MOQX.Transport.Connection{
  backend: %MOQX.Transport.BackendRef{module: module(), data: term()},
  local_role: :client | :server
}

%MOQX.Transport.Stream{
  backend: %MOQX.Transport.BackendRef{module: module(), data: term()},
  info: %MOQX.Transport.StreamInfo{}
}
```

`BackendRef.data` is opaque to protocol code and may contain backend-specific structs such as `%MOQX.Transport.Quicer.Connection{handle: raw}` or support-transport private state.

Each handle carries its backend module. The façade validates that handles used with a context belong to the same backend and returns a stable error such as `{:error, :backend_mismatch, ctx}` on mismatch.

A single context may track multiple listeners, connections, and streams owned by one logical process.

### Backend callback style

Backend implementation callbacks receive wrapper structs and backend-private context data, not naked raw handles from protocol code. Backends unwrap their own opaque data internally.

Example shape:

```elixir
@callback open_stream(backend_state, MOQX.Transport.Connection.t(), opts) ::
            {:ok, backend_state, MOQX.Transport.Stream.t()} |
            {:error, term(), backend_state}
```

Exact callback names/signatures may be adjusted during implementation, but the public façade must keep context-last tuples.

### Stream info is first-class

Add `%MOQX.Transport.StreamInfo{}` and `Transport.stream_info/2`.

Required fields:

```elixir
%MOQX.Transport.StreamInfo{
  stream_id: non_neg_integer(),
  direction: :bidirectional | :unidirectional,
  initiator: :local | :peer,
  initiator_role: :client | :server,
  local_role: :client | :server,
  send_side?: boolean(),
  receive_side?: boolean()
}
```

Do not use `:unknown` for role/direction/side fields. If a backend cannot construct exact stream info, it must return an error rather than expose uncertain metadata to protocol code.

Support transport should assign QUIC-shaped stream IDs, not arbitrary counters. QUIC stream IDs encode client/server initiator and bidirectional/unidirectional direction in the low bits. This keeps support-transport debugging and contract tests aligned with real QUIC behavior.

### Shutdown API uses local-intent names

Remove the ambiguous `close_stream/2` callback. Replace it with explicit local-intent callbacks/façade functions:

```elixir
finish_sending(ctx, stream)
abort_sending(ctx, stream, error_code)
abort_receiving(ctx, stream, error_code)
close_connection(ctx, connection, error_code)
```

Application error codes are `non_neg_integer()` values at the transport layer. Protocol modules may later provide named translation tables, but raw transport does not interpret MOQT draft-specific code names.

Each shutdown function returns when the backend accepts/initiates the operation, not when the lifecycle is fully complete. Completion is observed through normalized events.

Function documentation must clearly state, for each callback/façade function:

- local caller intent;
- QUIC mechanism;
- peer observation;
- completion semantics;
- stream-side directionality and invalid-direction behavior.

Canonical mapping:

| Public operation | Local intent | QUIC mechanism | Peer observes |
| --- | --- | --- | --- |
| `finish_sending/2` | We completed our send side successfully | FIN | `:peer_finished_sending` |
| `abort_sending/3` | We abort our send side with an app error code | RESET_STREAM | `:peer_aborted_sending` |
| `abort_receiving/3` | We no longer want to receive on this stream | STOP_SENDING | `:peer_aborted_receiving` |
| `close_connection/3` | We close the whole connection with an app error code | CONNECTION_CLOSE | connection `:closed` |

Invalid stream-side operations should return stable errors where the stream info makes this knowable:

```elixir
{:error, :send_side_unavailable, ctx}
{:error, :receive_side_unavailable, ctx}
```

Examples:

- `finish_sending/2` and `abort_sending/3` fail on peer-initiated unidirectional streams.
- `abort_receiving/3` fails on local-initiated unidirectional streams.
- Bidirectional streams support all three operations.

### Normalized event vocabulary

Move normalized stream shutdown events away from raw `quicer` event names.

Canonical stream events:

```elixir
:peer_finished_sending
:peer_aborted_sending
:peer_aborted_receiving
:sending_finished
:sending_aborted
:closed
```

Connection close uses one canonical event with normalized metadata:

```elixir
{:connection_event, connection, :closed,
 %{error_code: non_neg_integer() | :unknown,
   initiator: :local | :peer | :unknown}}
```

Stream event tuples should carry `%MOQX.Transport.Stream{}` values. Do not duplicate `stream.info` into event metadata; metadata should be event-specific only, such as `%{error_code: code}` or backend status details where useful and documented.

### Context-aware event normalization

`MOQX.Transport.receive_event(ctx, timeout)` receives one backend mailbox message and normalizes it using context backend state/registries.

Semantics:

- `{:unknown, message, ctx}` means the message is not recognized as a transport/backend message for this backend.
- `{:error, reason, ctx}` means the message appears transport-related but cannot be safely normalized.
- If a backend event references an unknown raw handle, auto-register it only when enough information exists to construct exact wrapper metadata.
- `:new_stream`-like events may auto-register peer-opened streams when stream ID, local role, direction, and initiator can be determined.
- Never emit a normalized stream event with unknown stream role/direction metadata.

### Whole-context ownership handoff

Replace per-handle `controlling_process/2` with strict whole-context handoff:

```elixir
{:ok, ctx} | {:error, reason, ctx} = MOQX.Transport.controlling_process(ctx, new_pid)
```

Semantics:

- Transfers every known listener, connection, and stream backend handle in the context to `new_pid` where the backend supports ownership transfer.
- The caller must send the returned context to `new_pid` and must not keep using stale copies.
- First implementation uses all-or-error semantics.
- For backends that cannot transactionalize handoff, document partial-transfer failure behavior clearly in the error reason.
- Support transport should make this exact and deterministic.

## Acceptance criteria

- [ ] `MOQX.Transport` exposes `new/2` and context-threaded façade functions with context-last tuples.
- [ ] Public protocol-facing tests use `MOQX.Transport.*` façade calls rather than direct backend calls, except backend-specific adapter/unit tests.
- [ ] Public wrapper structs exist for `Context`, `BackendRef`, `Listener`, `Connection`, `Stream`, and `StreamInfo`.
- [ ] Wrapper handles carry backend module plus backend-opaque data; protocol-visible fields expose only stable transport metadata.
- [ ] The façade validates backend/context mismatches and returns a stable error.
- [ ] `StreamInfo` includes exact `stream_id`, `direction`, `initiator`, `initiator_role`, `local_role`, `send_side?`, and `receive_side?` fields.
- [ ] Support transport assigns QUIC-shaped stream IDs and exact stream info for local/peer, bidirectional/unidirectional streams.
- [ ] `close_stream/2` is removed from the public transport behaviour/API.
- [ ] `finish_sending/2`, `abort_sending/3`, and `abort_receiving/3` exist and are documented with intent, QUIC mapping, peer observation, completion semantics, and directionality.
- [ ] Shutdown functions accept only `non_neg_integer()` application error codes where codes are required.
- [ ] Invalid send-side or receive-side shutdown operations return stable direction errors.
- [ ] `close_connection/3` initiates connection close with a `non_neg_integer()` application error code.
- [ ] Shared contract tests cover graceful finish-sending and normalized peer/local completion events.
- [ ] Shared contract tests cover abort-sending and preserve the application error code in normalized peer events where available.
- [ ] Shared contract tests cover abort-receiving / STOP_SENDING semantics and preserve the application error code in normalized peer events where available.
- [ ] Shared contract tests cover connection close behavior and normalized connection close events.
- [ ] Shared contract tests cover `Transport.stream_info/2` for bidirectional, local unidirectional, and peer unidirectional streams.
- [ ] Shared contract tests cover stale/unknown handle normalization errors instead of silently returning uncertain stream info.
- [ ] Whole-context `controlling_process/2` transfers all known listener/connection/stream handles or returns an all-or-error failure.
- [ ] The support transport updates ownership and message delivery according to the context handoff contract.
- [ ] The `quicer` adapter passes the same close/reset/ownership contract tests where local environment support is available.
- [ ] Any unsupported or backend-limited ownership, close, reset, or receive-abort behavior is explicitly documented.
- [ ] `MOQX.Transport` callback/function documentation is expanded generally so each public transport operation states caller intent, backend/QUIC mapping where relevant, event/peer observation, and ownership/context expectations.
- [ ] No `Application` env or mutable global registry is introduced as a test seam or transport state store.

## Blocked by

- `.scratch/transport-layer-foundation/issues/04-add-stream-lifecycle-contract.md`
- `.scratch/transport-layer-foundation/issues/05-add-datagram-contract.md`

## Design notes from grilling session

- Prefer clear local-intent API names over QUIC frame names: `abort_receiving/3` instead of public `stop_sending/3`.
- Protocol modules interpret application error code namespaces. Transport only carries integer codes.
- Context is a caller-owned state value, not a process/router. A future router remains possible if mailbox isolation or concurrent ownership becomes necessary.
- Unknown role/direction metadata is not acceptable for stream info; fail loudly instead.
- Whole-context handoff is intentionally stricter than per-handle handoff until a router or more advanced ownership model exists.

## Comments
