# ADR-0006: Protocol variants own session state; codec stays generic

- Status: Superseded by ADR-0010
- Date: 2026-06-05

## Context

`moqx` targets multiple MOQT-family protocols over the same native QUIC
transport foundation.

MOQT draft-14 and MOQ Lite draft-04 already diverge in their operating model:

- MOQT draft-14 negotiates native QUIC ALPN `moq-00`, requires QUIC DATAGRAM
  support, starts with CLIENT_SETUP/SERVER_SETUP on the first client-initiated
  bidirectional control stream, and uses request IDs plus object delivery over
  unidirectional streams and/or datagrams.
- MOQ Lite draft-04 negotiates native QUIC ALPN `moq-lite-04`, has no setup
  exchange, treats the session as active after the transport connection is
  established, uses many bidirectional transaction streams, uses publisher
  unidirectional group streams, and does not use datagrams.

The first MOQ Lite building block introduced `MOQX.MOQLite04` message structs,
stream type lookup helpers, and generic codec contracts under `MOQX.Codec`.

## Decision

Do not introduce a common protocol behaviour that hides draft-14 and MOQ Lite
behind one operating mode.

Each protocol variant owns its own message model, stream codec, and session
state machine:

- `MOQX.MOQLite04` owns MOQ Lite draft-04 constants, message structs, stream
  rules, and session behavior.
- A future draft-14 namespace will own draft-14 setup, control-stream,
  request-ID, datagram, and object-delivery behavior.
- Session reducer shape, naming, and transport-action boundaries are recorded
  separately in ADR-0007.

`MOQX.Codec` remains protocol-neutral. It hosts generic binary helpers and
contracts shared by protocol variants:

- `MOQX.Codec.Encoder` encodes typed values into payload iodata.
- `MOQX.Codec.Decoder` is a behaviour for modules that decode complete payload
  binaries into typed values.
- Protocol-specific modules implement or call those contracts where useful.

For MOQ Lite draft-04 specifically:

- `StreamType` is represented as a typespec and lookup helpers, not as a
  struct.
- Message structs model semantic payload fields only.
- Message length, stream type prefixes, buffering, FIN handling, and stream
  state dispatch belong to the MOQ Lite stream/session codec, not to message
  structs.
- Decoding is context-driven because the stream role determines which payload
  shape is valid next.

## Consequences

Positive:

- Draft-14 and MOQ Lite can evolve independently without a leaky abstraction
  that forces their state machines into the same shape.
- Shared binary primitives can still be reused through `MOQX.Codec`.
- MOQ Lite tests can exercise stream transactions without draft-14 setup or
  datagram assumptions.
- Draft-14 can later keep its request ID and datagram behavior without being
  constrained by MOQ Lite's stream-per-transaction model.

Tradeoffs:

- Some public APIs may need thin variant-specific entrypoints instead of one
  universal protocol client.
- Shared concepts must be intentionally factored into `MOQX.Codec` or
  `MOQX.Transport`; otherwise variant code may duplicate small pieces.
- The session layer must explicitly choose the right variant instead of relying
  on a hidden common protocol behaviour.

## Non-goals

This ADR does not decide:

- the final public client API;
- the final MOQ Lite session process topology;
- exact binary helper names inside `MOQX.Codec`;
- draft-14 message structs or setup encoding;
- WebTransport support.

## References

- `docs/adr/0007-protocol-sessions-are-pure-reducers.md`
- `docs/adr/0010-compose-versioned-wire-packages-into-explicit-protocol-implementations.md`
