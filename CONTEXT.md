# MOQX Transport Context

This context describes the transport vocabulary used by `moqx` protocol implementations over native QUIC. It exists to keep MOQT-family protocol code independent of backend-specific `quicer` terminology while preserving QUIC shutdown semantics.

## Language

**Finish Sending**:
A graceful local send-side stream completion that tells the peer no more bytes will be sent without treating the stream as failed.
_Avoid_: close stream, normal close, finish stream

**Abort Sending**:
An abortive local send-side stream termination carrying an application error code to the peer.
_Avoid_: close stream with reason, cancellation, reset stream

**Abort Receiving**:
An abortive local receive-side stream termination carrying an application error code that tells the peer to stop sending.
_Avoid_: stop sending, stop receiving, close receive side

**Connection Close**:
A connection-level shutdown carrying a transport-visible application error code where the backend supports it.
_Avoid_: disconnect, socket close

**Application Error Code**:
An unsigned integer selected by the protocol layer and carried by QUIC stream or connection shutdown signals.
_Avoid_: reason atom, exception reason

**Transport Profile**:
A named fixture that records protocol-selected ALPN, transport capabilities, and protocol-level stream expectations for tests and benchmarks.
Current profiles are `:draft_14` and `:moq_lite_04`.
_Avoid_: protocol implementation, session implementation

**Protocol Variant**:
A concrete MOQT-family protocol version with its own message model and session
rules, such as MOQ Lite draft-04 or MOQT draft-14.
_Avoid_: generic protocol behaviour, transport profile

**Protocol Session**:
A variant-owned state machine for one negotiated MOQT-family relationship over
one transport connection. A protocol session owns stream state, role-specific
rules, protocol events, and transport actions.
_Avoid_: connection, socket, transport handle

**Protocol Command**:
Local application intent submitted to a **Protocol Session**, such as subscribe,
fetch, publish a frame, or goaway.
_Avoid_: encode data, send raw bytes

**Protocol Event**:
Typed output emitted by a **Protocol Session** for application code. Events that
come from streams remain tagged with a stream identity.
_Avoid_: raw transport message, decoded bytes

**Transport Action**:
A side effect requested by a **Protocol Session** and later applied by a runner
through `MOQX.Transport`, such as opening a stream, sending bytes, finishing a
send side, aborting a stream side, or closing a connection.
_Avoid_: direct quicer call, protocol callback side effect

**Codec**:
Shared protocol-neutral binary helpers and encoder/decoder contracts under
`MOQX.Codec`.
_Avoid_: session codec, transport adapter

**Payload Codec**:
Encoding or decoding for one typed protocol payload after stream framing has
identified the payload shape and removed length fields.
_Avoid_: stream parser, state machine

**Stream Codec**:
Protocol-specific framing logic that reads stream type prefixes, message
lengths, and ordered byte buffers before dispatching complete payloads.
_Avoid_: payload codec, transport receive

**Transaction Stream**:
A MOQ Lite bidirectional stream whose first byte identifies an Announce,
Subscribe, Fetch, Probe, or Goaway transaction.
_Avoid_: control stream, data stream

**Group Stream**:
A MOQ Lite publisher-created unidirectional stream that starts with a GROUP
message and then carries FRAME messages for that group.
_Avoid_: object stream, subgroup stream

**Stream Side**:
One directional half of a stream, either local sending or local receiving.
_Avoid_: half-connection, close direction

## Relationships

- **Finish Sending** affects the local sending **Stream Side** of exactly one stream and maps to QUIC FIN.
- A stream send accepted with `finish: true` carries the final payload and **Finish Sending** in one ordered send request.
- A standalone **Finish Sending** is a FIN-only operation ordered after previously accepted sends on the same stream owner path.
- **Abort Sending** affects the local sending **Stream Side** of exactly one stream and maps to QUIC RESET_STREAM.
- **Abort Receiving** affects the local receiving **Stream Side** of exactly one stream and maps to QUIC STOP_SENDING.
- A **Connection Close** ends the connection and may implicitly close all streams on that connection.
- An **Application Error Code** is interpreted by protocol modules, not by the raw transport boundary.
- A **Transport Profile** can describe protocol-specific stream expectations,
  but the raw transport boundary still exposes generic QUIC streams and does
  not enforce those protocol rules.
- A **Protocol Variant** consumes **Transport** events and enforces its own
  stream/session rules above the raw transport boundary.
- A **Protocol Session** runs above one `MOQX.Transport.Connection`; the raw
  connection handle remains transport vocabulary, while session names belong to
  protocol vocabulary.
- A **Protocol Session** consumes transport input through `handle_transport/2`
  and local application input through `handle_command/2`.
- A **Protocol Session** returns **Transport Actions** as data. A runner applies
  those actions through `MOQX.Transport`.
- A **Protocol Session** may merge decoded outputs into one logical event
  stream, but stream-derived **Protocol Events** must preserve stream identity.
- A **Stream Codec** owns framing and buffering before invoking a
  **Payload Codec** for complete typed payloads.
- A **Stream Codec** is kept per transport stream. Raw bytes from different
  transport streams are never muxed together before decoding.
- MOQ Lite **Transaction Streams** and **Group Streams** are protocol rules,
  not transport-layer stream types.

## Example dialogue

> **Dev:** "When an object expires, should we use **Finish Sending**?"
> **Domain expert:** "No — expiry is **Abort Sending** with an application error code. **Finish Sending** means the sender completed successfully."

## Flagged ambiguities

- "close stream" was overloaded to mean graceful finish, reset, or receive abort — resolved: use explicit **Finish Sending**, **Abort Sending**, and **Abort Receiving** terms.
- "stop sending" sounds like local send-side intent but names QUIC's peer-directed STOP_SENDING mechanism — resolved: public transport APIs use **Abort Receiving** instead.
