# ADR-0007: Protocol sessions are pure reducers

- Status: Accepted
- Date: 2026-06-05

## Context

`moqx` already separates raw transport mechanics from MOQT-family protocol
variants. The next MOQ Lite draft-04 slice needs a stateful layer above
`MOQX.Transport` that can consume stream bytes, enforce stream rules, and expose
typed protocol events without binding the protocol state machine to a process or
to `quicer`.

The relevant protocol terminology uses "session" for the protocol relationship
running over a raw QUIC connection or a WebTransport session. In MOQ Lite
draft-04, the session is active immediately after the transport connection is
established and stream probing is used for extensions. In MOQT draft-14, a
Transport Session is likewise the abstraction over native QUIC or WebTransport.

Mint and `mint_web_socket` provide useful prior art:

- connection/session state is explicit and returned from API calls;
- incoming transport messages are classified before protocol handling;
- HTTP/2 request streams keep stable identities and responses are tagged with
  request refs;
- WebSocket frame decoding is layered on top of Mint HTTP data events and keeps
  its own incremental buffer.

## Decision

Name the upper protocol state machine a `Session`, not a `Connection`.

`Conn` remains transport vocabulary and should refer to
`MOQX.Transport.Conn` or backend connection handles. `Session` is protocol
vocabulary and should refer to a variant-owned state machine such as
`MOQX.MOQLite04.Session`.

Protocol sessions are pure reducers. They consume input state and return updated
state, protocol events, and transport actions as data. They do not call
`MOQX.Transport`, `quicer`, or process APIs directly.

Protocol failures are represented internally as structured variant errors such
as `MOQX.MOQLite04.Error`. Integer transport application error codes appear at
the transport-action boundary, not throughout the reducer logic.

The reducer boundary has two directions:

- `handle_transport/2` consumes normalized `MOQX.Transport` events from the
  peer or transport.
- `handle_command/2` consumes local application intent and produces encoded
  transport actions when valid.

The callback names describe semantic state transitions rather than byte
encoding. `handle_command/2` is preferred over names such as `encode/2` because
a command may open streams, reject work after GOAWAY, update session state,
encode messages, finish sending, or abort stream sides.

Transport stream identity must be preserved. QUIC streams are independent
ordered byte streams with no cross-stream ordering guarantee, so raw bytes from
different streams must never be muxed together before stream decoding. A
session may emit one logical stream of protocol events, but stream-derived
events must be tagged with a stream identity or ref.

## API Shape

A future shared behaviour may use this shape when draft-14 and MOQ Lite have
enough common reducer mechanics:

```elixir
@callback handle_transport(t(), MOQX.Transport.event()) ::
            :unknown
            | {:ok, t(), [protocol_event()], [transport_action()]}
            | {:error, t(), reason :: term(), [protocol_event()],
               [transport_action()]}

@callback handle_command(t(), command()) ::
            {:ok, t(), [protocol_event()], [transport_action()]}
            | {:error, t(), reason :: term(), [protocol_event()],
               [transport_action()]}
```

The first implementation does not need to introduce this behaviour. The
behaviour should appear only after at least one protocol session proves the
shape and draft-14 work confirms the common boundary.

## Consequences

Positive:

- MOQ Lite session tests can be deterministic and process-free.
- Protocol logic remains independent of raw `quicer` messages.
- A runner can apply transport actions using any `MOQX.Transport` backend.
- The session layer can preserve per-stream buffers, stream type, side, and
  role state while still producing one application-facing protocol event list.
- Structured protocol errors keep reset/close decisions auditable before they
  are converted into transport integer codes.
- The design leaves room for a future shared session behaviour without forcing
  draft-14 and MOQ Lite into one operating mode.

Tradeoffs:

- A runner layer is required to apply returned transport actions.
- The session reducer must model enough stream identity to correlate transport
  events, protocol events, and local commands.
- API callers must retain the returned session state after every call.

## Non-goals

This ADR does not decide:

- the final public client API;
- the process topology for production stream ownership;
- exact protocol event, command, or transport action tuple names;
- draft-14 control stream or datagram state;
- WebTransport support.

## References

- <https://datatracker.ietf.org/doc/html/draft-lcurley-moq-lite-04>
- <https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-14>
- <https://github.com/elixir-mint/mint>
- <https://github.com/elixir-mint/mint_web_socket>
