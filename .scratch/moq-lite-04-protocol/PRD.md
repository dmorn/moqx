# MOQ Lite 04 protocol layer

Status: in-progress

## Problem Statement

`moqx` has a protocol-neutral QUIC transport foundation and now has initial MOQ
Lite draft-04 message structs plus generic `MOQX.Codec` contracts. The next
work is to turn those building blocks into a real MOQ Lite protocol layer.

The transport PRD intentionally keeps "Full MOQ Lite implementation" out of
scope. This PRD tracks the upper-layer work: MOQ Lite wire codecs, stream
framing, and the protocol state machine that runs above `MOQX.Transport`.

Relevant draft facts for this scope:

- MOQ Lite draft-04 uses ALPN `moq-lite-04` for bare QUIC.
- The session is active immediately after connection establishment; there is no
  CLIENT_SETUP/SERVER_SETUP exchange.
- Bidirectional transaction streams are used for Announce, Subscribe, Fetch,
  Probe, and Goaway.
- Publisher-created unidirectional Group Streams start with GROUP and then
  carry FRAME messages.
- Unknown stream types are reset for extension probing rather than treated as a
  connection-level protocol failure.
- Most messages carry a message length field, but that framing field is not
  part of the semantic message struct.

## Solution

Build `MOQX.MOQLite04` as its own protocol variant on top of `MOQX.Transport`.

The implementation should proceed in narrow slices:

1. Define semantic message structs and stream type lookup helpers.
2. Add shared binary helpers in `MOQX.Codec` for the integer/string/bytes
   primitives needed by MOQ Lite and future draft-14 work.
3. Implement MOQ Lite payload encoders and decoders for every message struct.
4. Add a MOQ Lite stream codec that handles stream type prefixes, message
   length fields, buffering, and payload decoder selection.
5. Add a MOQ Lite session/stream state machine that enforces stream roles,
   message ordering, graceful finish, abort sending, abort receiving, and
   connection close behavior using `MOQX.Transport`.

## User Stories

1. As a MOQ Lite client implementer, I want typed message structs so protocol
   code can be written against Elixir values rather than ad hoc maps or raw
   binaries.
2. As a codec implementer, I want shared `MOQX.Codec` helpers so draft-14 and
   MOQ Lite do not duplicate variable-length integer, string, and byte payload
   parsing.
3. As a protocol implementer, I want payload encoders and decoders to be
   independent of stream buffering so they can be tested with simple binaries.
4. As a session implementer, I want a stream codec that owns message lengths
   and incomplete buffers so transport events can be converted into complete
   messages deterministically.
5. As a MOQ Lite endpoint, I want transaction stream state to reject invalid
   message order, such as SUBSCRIBE_DROP before the first SUBSCRIBE_OK.
6. As a subscriber, I want Fetch Streams to return FRAME messages directly on
   the same bidirectional stream without a GROUP header.
7. As a publisher, I want Group Streams to start with GROUP and then emit
   ordered FRAME payloads until Finish Sending or Abort Sending.
8. As a future draft-14 implementer, I want this work to avoid a common
   protocol behaviour that would force draft-14 into MOQ Lite's stream model.

## Implementation Decisions

- `MOQX.Transport` remains the only transport boundary used by the protocol
  layer.
- Protocol code must not match raw `quicer` messages.
- `MOQX.Codec` is generic. It must not contain MOQ Lite stream roles, message
  atom tables, or session state.
- `MOQX.MOQLite04` owns MOQ Lite draft-04 message structs, stream type lookup,
  stream codec, and session state.
- `StreamType` remains a typespec plus lookup helpers, not a struct.
- Message structs contain semantic payload fields only. Message length is a
  stream/message framing concern.
- Decoder selection is stream-state dependent. A single decode-anything
  function should not guess message type without context.
- The first implementation targets native QUIC and ALPN `moq-lite-04`;
  WebTransport remains out of scope.
- Session APIs must receive explicit options or structs. Do not use
  `Application` env as a test seam or mutable global configuration.

## Testing Decisions

Default tests should stay fast and deterministic.

Initial coverage should include:

- `MOQX.Codec` primitive round-trip and boundary tests;
- payload encoder/decoder round-trip tests for every MOQ Lite message struct;
- invalid enum, invalid length, incomplete buffer, and trailing-bytes errors;
- stream codec tests for stream type prefixes and message length stripping;
- pure state-machine tests for Announce, Subscribe, Fetch, Probe, Goaway, and
  Group stream transitions;
- support-transport tests showing the state machine consumes normalized
  `MOQX.Transport` events rather than raw `quicer` events.

Real QUIC or interop tests should stay tagged `:integration` and remain
explicitly invoked.

## Out of Scope

- MOQT draft-14 protocol implementation.
- WebTransport-over-HTTP/3 support.
- Media payload parsing or codec/container awareness.
- Production scheduling, caching, and relay fanout policy beyond the minimal
  protocol state needed to exchange messages.
- External MOQ Lite relay interoperability as a default unit-test requirement.

## Progress

Initial building block commit:

- `3dc2a14 Add moq-lite message model and codec contracts`

Delivered so far:

- `MOQX.Codec`
- `MOQX.Codec.Encoder`
- `MOQX.Codec.Decoder`
- `MOQX.MOQLite04` stream type lookup helpers
- `MOQX.MOQLite04` message structs for Announce, Subscribe, Fetch, Probe,
  Goaway, Group, and Frame messages

## References

- <https://datatracker.ietf.org/doc/html/draft-lcurley-moq-lite-04>
- <https://datatracker.ietf.org/doc/draft-ietf-moq-transport/14/>
- `docs/adr/0001-transport-boundary-support-transport-and-benchmark-harness.md`
- `docs/adr/0002-native-quic-first-webtransport-out-of-scope.md`
- `docs/adr/0003-validated-endpoints-above-raw-transport.md`
- `docs/adr/0006-protocol-variants-own-session-state-codec-stays-generic.md`
