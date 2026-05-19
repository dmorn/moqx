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

**Stream Side**:
One directional half of a stream, either local sending or local receiving.
_Avoid_: half-connection, close direction

## Relationships

- **Finish Sending** affects the local sending **Stream Side** of exactly one stream and maps to QUIC FIN.
- **Abort Sending** affects the local sending **Stream Side** of exactly one stream and maps to QUIC RESET_STREAM.
- **Abort Receiving** affects the local receiving **Stream Side** of exactly one stream and maps to QUIC STOP_SENDING.
- A **Connection Close** ends the connection and may implicitly close all streams on that connection.
- An **Application Error Code** is interpreted by protocol modules, not by the raw transport boundary.
- A **Transport Profile** can describe protocol-specific stream expectations,
  but the raw transport boundary still exposes generic QUIC streams and does
  not enforce those protocol rules.

## Example dialogue

> **Dev:** "When an object expires, should we use **Finish Sending**?"
> **Domain expert:** "No — expiry is **Abort Sending** with an application error code. **Finish Sending** means the sender completed successfully."

## Flagged ambiguities

- "close stream" was overloaded to mean graceful finish, reset, or receive abort — resolved: use explicit **Finish Sending**, **Abort Sending**, and **Abort Receiving** terms.
- "stop sending" sounds like local send-side intent but names QUIC's peer-directed STOP_SENDING mechanism — resolved: public transport APIs use **Abort Receiving** instead.
