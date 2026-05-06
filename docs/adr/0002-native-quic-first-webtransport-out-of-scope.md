# ADR-0002: Native QUIC first; WebTransport out of initial scope

- Status: Accepted
- Date: 2026-05-06

## Context

MOQT draft-14 can run over native QUIC or over WebTransport. WebTransport runs over HTTP/3, which runs over QUIC, and is primarily useful for browser-facing deployments where applications cannot open raw QUIC sockets directly.

`moqx` is intended initially for native relay-side communication:

```text
relay <-> moqx <-> relay
```

In this topology, `moqx` is not addressed directly by browsers and does not need the browser/WebTransport API surface. The current transport implementation is based on `quicer`, which exposes native QUIC streams and datagrams directly.

The `moq-dev/moq` project and related documentation mention WebTransport together with QUIC because they support both browser/WebTransport clients and native QUIC clients. Their native-client documentation distinguishes `https://` WebTransport-over-HTTP/3 connections from raw QUIC schemes.

## Decision

`moqx` will initially target native QUIC MOQT only.

Initial transport scope:

- native QUIC via `quicer`;
- protocol-selected native QUIC ALPN, including `moq-00` for MOQT draft-14 and `moq-lite-xx`-style tokens for MOQ Lite;
- QUIC streams directly;
- QUIC datagrams directly;
- relay-to-relay or server-side deployment use cases.

WebTransport is out of initial implementation scope.

Out-of-scope WebTransport concerns include:

- HTTP/3 session setup;
- WebTransport session negotiation;
- HTTP Datagrams and capsule handling above QUIC;
- browser API compatibility;
- `https://` WebTransport endpoint behavior.

The transport abstraction should not prevent a future WebTransport backend. A future implementation could add a separate transport module if a browser-facing or HTTP/3 deployment requirement appears.

## Consequences

Positive:

- The initial implementation can focus on the transport path needed by relay-side deployments.
- The protocol layer can use native QUIC streams and datagrams without introducing HTTP/3/WebTransport complexity.
- Benchmark and contract-test work can target the actual deployment path first.
- `quicer` remains an appropriate initial backend.

Tradeoffs:

- `moqx` will not initially support browser clients directly.
- It will not initially interoperate with endpoints that only expose MOQT over WebTransport/HTTP/3.
- Future WebTransport support may require an additional backend and additional session-establishment logic.

## Non-goals

This ADR does not decide:

- whether `moqx` will ever support WebTransport;
- which HTTP/3/WebTransport library would be used if support is added;
- URL scheme handling for future clients;
- final MOQT draft-version negotiation behavior.
